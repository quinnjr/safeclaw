use std::sync::{Arc, OnceLock, Weak};

use async_trait::async_trait;
use chrono::{Datelike, Timelike};
use chrono_tz::America::New_York;
use daimon::mcp::protocol::McpToolInfo;
use daimon::mcp::{HttpTransport, McpClient, StdioTransport};
use serde_json::json;
use tokio::sync::OnceCell;

use super::{Tool, ToolContext, ToolOutput};
use crate::agent::Agent;
use crate::error::{Result, SafeAgentError};

const ROBINHOOD_TOKEN_ENV: &str = "ROBINHOOD_MCP_TOKEN";

/// Robinhood agentic trading — quote/positions/account are proxied to
/// whatever MCP server `mcp_connection` points at (Robinhood's official
/// Trading MCP by default), plus a locally-owned watchlist and paper-order
/// log. `paper_order` never calls the MCP server or any network endpoint;
/// it only logs a simulated decision, so there is no code path in this
/// tool that can place a real order regardless of what the connected MCP
/// server exposes. The `tick` action runs one full LLM-reasoned pass over
/// the watchlist by delegating to the `trader` persona in a sub-session,
/// so the fixed scaffold (defined in the persona) and the user-editable
/// strategy (session prompt, from `trading_config`) stay separate.
pub struct RobinhoodTool {
    agent_ref: Arc<OnceLock<Weak<Agent>>>,
    connection: String,
    mcp: OnceCell<McpClient>,
}

impl RobinhoodTool {
    pub fn new(agent_ref: Arc<OnceLock<Weak<Agent>>>, connection: impl Into<String>) -> Self {
        Self {
            agent_ref,
            connection: connection.into(),
            mcp: OnceCell::new(),
        }
    }

    fn agent(&self) -> Result<Arc<Agent>> {
        self.agent_ref
            .get()
            .and_then(|w| w.upgrade())
            .ok_or_else(|| SafeAgentError::Tool("agent not initialized".into()))
    }

    /// Connects on first use and caches the client for the tool's lifetime.
    async fn mcp_client(&self) -> Result<&McpClient> {
        self.mcp
            .get_or_try_init(|| Self::connect(&self.connection))
            .await
    }

    /// An `http(s)://` connection string speaks Streamable HTTP (Robinhood's
    /// official Trading MCP); anything else is treated as a command line and
    /// spawned over stdio, e.g. a local authenticating proxy.
    async fn connect(connection: &str) -> Result<McpClient> {
        let connection = connection.trim();
        if connection.is_empty() {
            return Err(SafeAgentError::Config("trading.mcp_connection is empty".into()));
        }

        if connection.starts_with("http://") || connection.starts_with("https://") {
            let mut transport = HttpTransport::new(connection);
            if let Ok(token) = std::env::var(ROBINHOOD_TOKEN_ENV) {
                if !token.is_empty() {
                    transport = transport.with_header("Authorization", format!("Bearer {token}"));
                }
            }
            McpClient::connect(transport)
                .await
                .map_err(|e| SafeAgentError::Tool(format!("Robinhood MCP connect failed: {e}")))
        } else {
            let mut parts = connection.split_whitespace();
            let command = parts
                .next()
                .ok_or_else(|| SafeAgentError::Config("trading.mcp_connection is empty".into()))?;
            let args: Vec<&str> = parts.collect();
            let transport = StdioTransport::new(command, args)
                .await
                .map_err(|e| SafeAgentError::Tool(format!("Robinhood MCP spawn failed: {e}")))?;
            McpClient::connect(transport)
                .await
                .map_err(|e| SafeAgentError::Tool(format!("Robinhood MCP handshake failed: {e}")))
        }
    }

    /// Finds the first discovered MCP tool whose name or description
    /// matches one of `keywords` (case-insensitive). Robinhood doesn't
    /// publish a fixed tool-name contract for third-party MCP clients, so
    /// read-only actions resolve by keyword against the server's own
    /// `tools/list` response rather than a hardcoded name.
    fn find_tool<'a>(client: &'a McpClient, keywords: &[&str]) -> Option<&'a McpToolInfo> {
        client.tool_infos().iter().find(|t| {
            let haystack = format!("{} {}", t.name, t.description.as_deref().unwrap_or(""))
                .to_lowercase();
            keywords.iter().any(|k| haystack.contains(k))
        })
    }

    /// Builds `{ <ticker-property>: symbol }` from the tool's declared
    /// input schema, so the argument key matches whatever the server calls
    /// it (symbol/ticker/instrument) instead of guessing one name.
    fn build_symbol_args(tool: &McpToolInfo, symbol: &str) -> serde_json::Value {
        let key = tool
            .input_schema
            .get("properties")
            .and_then(|p| p.as_object())
            .and_then(|props| {
                props
                    .keys()
                    .find(|k| matches!(k.to_lowercase().as_str(), "symbol" | "ticker" | "instrument"))
            })
            .cloned()
            .unwrap_or_else(|| "symbol".to_string());
        json!({ key: symbol })
    }

    /// Resolves a read-only role (quote/positions/account) to a discovered
    /// MCP tool by keyword and calls it. Deliberately has no equivalent for
    /// order placement — that stays local-only via `paper_order`.
    async fn call_readonly(&self, keywords: &[&str], role: &str, symbol: Option<&str>) -> Result<ToolOutput> {
        let client = self.mcp_client().await?;
        let Some(tool) = Self::find_tool(client, keywords) else {
            return Ok(ToolOutput::error(format!(
                "no MCP tool matching '{role}' was found on the connected server; \
                 use action=mcp_list_tools to see what's available"
            )));
        };
        let args = symbol
            .map(|s| Self::build_symbol_args(tool, s))
            .unwrap_or_else(|| json!({}));
        let name = tool.name.clone();

        match client.call_tool(&name, &args).await {
            Ok(text) => Ok(ToolOutput::ok_with_meta(text, json!({ "mcp_tool": name }))),
            Err(e) => Ok(ToolOutput::error(format!("MCP tool '{name}' call failed: {e}"))),
        }
    }
}

/// True during US equity regular trading hours (9:30-16:00 ET, Mon-Fri).
/// Holidays aren't accounted for — a closed-market tick just finds no fresh
/// quotes and is a no-op cost, not a correctness bug.
pub fn is_market_hours(now_utc: chrono::DateTime<chrono::Utc>) -> bool {
    let now = now_utc.with_timezone(&New_York);
    let weekday = now.weekday();
    if matches!(weekday, chrono::Weekday::Sat | chrono::Weekday::Sun) {
        return false;
    }
    let minutes_since_midnight = now.hour() * 60 + now.minute();
    (9 * 60 + 30..16 * 60).contains(&minutes_since_midnight)
}

#[async_trait]
impl Tool for RobinhoodTool {
    fn name(&self) -> &str {
        "trading"
    }

    fn description(&self) -> &str {
        "Robinhood agentic paper-trading over MCP. Actions: quote, positions, \
         account (proxied read-only to the connected Robinhood Trading MCP \
         server), mcp_list_tools (debug: list tools the server exposes), \
         watchlist_add, watchlist_remove, watchlist_list (agent-managed \
         symbol list, local), paper_order (logs a simulated buy/sell \
         decision locally, never calls the MCP server or places a real \
         order), tick (runs one full reasoning pass over the watchlist)."
    }

    fn parameters_schema(&self) -> serde_json::Value {
        json!({
            "type": "object",
            "required": ["action"],
            "properties": {
                "action": {
                    "type": "string",
                    "enum": ["quote", "positions", "account", "mcp_list_tools", "watchlist_add", "watchlist_remove", "watchlist_list", "paper_order", "tick"],
                    "description": "Action to perform"
                },
                "symbol": {
                    "type": "string",
                    "description": "Ticker symbol (for quote, watchlist_add, watchlist_remove, paper_order)"
                },
                "side": {
                    "type": "string",
                    "enum": ["buy", "sell"],
                    "description": "Order side (for paper_order)"
                },
                "qty": {
                    "type": "number",
                    "description": "Quantity of shares (for paper_order)"
                },
                "price": {
                    "type": "number",
                    "description": "Price at decision time, from a prior `quote` call (for paper_order)"
                },
                "rationale": {
                    "type": "string",
                    "description": "Reasoning behind the decision, including holds (for paper_order)"
                }
            }
        })
    }

    async fn execute(&self, params: serde_json::Value, ctx: &ToolContext) -> Result<ToolOutput> {
        let action = params.get("action").and_then(|v| v.as_str()).unwrap_or_default();

        match action {
            "quote" => {
                let symbol = params.get("symbol").and_then(|v| v.as_str()).unwrap_or_default();
                if symbol.is_empty() {
                    return Ok(ToolOutput::error("symbol is required for quote"));
                }
                self.call_readonly(&["quote", "price"], "quote", Some(symbol)).await
            }
            "positions" => self.call_readonly(&["position"], "positions", None).await,
            "account" => {
                self.call_readonly(&["account", "portfolio", "balance"], "account", None).await
            }
            "mcp_list_tools" => {
                let client = self.mcp_client().await?;
                let listing: Vec<String> = client
                    .tool_infos()
                    .iter()
                    .map(|t| format!("{}: {}", t.name, t.description.as_deref().unwrap_or("")))
                    .collect();
                if listing.is_empty() {
                    Ok(ToolOutput::ok("Connected server exposes no tools."))
                } else {
                    Ok(ToolOutput::ok(listing.join("\n")))
                }
            }
            "watchlist_add" => {
                let symbol = params.get("symbol").and_then(|v| v.as_str()).unwrap_or_default();
                if symbol.is_empty() {
                    return Ok(ToolOutput::error("symbol is required for watchlist_add"));
                }
                let symbol = symbol.to_uppercase();
                let db = ctx.db.lock().await;
                db.execute(
                    "INSERT OR IGNORE INTO watchlist (symbol) VALUES (?1)",
                    [&symbol],
                )?;
                Ok(ToolOutput::ok(format!("Added {symbol} to watchlist")))
            }
            "watchlist_remove" => {
                let symbol = params.get("symbol").and_then(|v| v.as_str()).unwrap_or_default();
                if symbol.is_empty() {
                    return Ok(ToolOutput::error("symbol is required for watchlist_remove"));
                }
                let symbol = symbol.to_uppercase();
                let db = ctx.db.lock().await;
                let rows = db.execute("DELETE FROM watchlist WHERE symbol = ?1", [&symbol])?;
                if rows > 0 {
                    Ok(ToolOutput::ok(format!("Removed {symbol} from watchlist")))
                } else {
                    Ok(ToolOutput::error(format!("{symbol} was not on the watchlist")))
                }
            }
            "watchlist_list" => {
                let db = ctx.db.lock().await;
                let mut stmt = db.prepare("SELECT symbol FROM watchlist ORDER BY added_at")?;
                let symbols: Vec<String> = stmt
                    .query_map([], |row| row.get(0))?
                    .collect::<std::result::Result<Vec<_>, _>>()?;
                if symbols.is_empty() {
                    Ok(ToolOutput::ok("Watchlist is empty."))
                } else {
                    Ok(ToolOutput::ok_with_meta(symbols.join(", "), json!({ "symbols": symbols })))
                }
            }
            "paper_order" => {
                // Pure DB write — deliberately never calls the MCP server
                // or any network endpoint. Price comes from the caller's
                // own prior `quote` call, not fetched again here. This is
                // the only order-placing path this tool has; there is no
                // action that forwards to whatever real order tool the
                // connected MCP server exposes.
                let symbol = params.get("symbol").and_then(|v| v.as_str()).unwrap_or_default();
                let side = params.get("side").and_then(|v| v.as_str()).unwrap_or_default();
                let qty = params.get("qty").and_then(|v| v.as_f64()).unwrap_or_default();
                let price = params.get("price").and_then(|v| v.as_f64());
                let rationale = params.get("rationale").and_then(|v| v.as_str()).unwrap_or_default();

                if symbol.is_empty() || side.is_empty() || rationale.is_empty() || price.is_none() {
                    return Ok(ToolOutput::error("symbol, side, price, and rationale are required for paper_order"));
                }
                if !matches!(side, "buy" | "sell") {
                    return Ok(ToolOutput::error("side must be 'buy' or 'sell'"));
                }

                let symbol = symbol.to_uppercase();
                let price = price.unwrap();

                let db = ctx.db.lock().await;
                db.execute(
                    "INSERT INTO paper_trades (symbol, side, qty, price, rationale) VALUES (?1, ?2, ?3, ?4, ?5)",
                    rusqlite::params![symbol, side, qty, price, rationale],
                )?;

                Ok(ToolOutput::ok(format!(
                    "Logged paper {side} of {qty} {symbol} @ {price:.2} (simulated only, no real order placed)"
                )))
            }
            "tick" => {
                if !is_market_hours(chrono::Utc::now()) {
                    return Ok(ToolOutput::ok("Market is closed — skipping tick."));
                }

                let agent = self.agent()?;
                let strategy: String = {
                    let db = ctx.db.lock().await;
                    db.query_row("SELECT strategy FROM trading_config WHERE id = 1", [], |row| row.get(0))
                        .unwrap_or_default()
                };
                let task = if strategy.trim().is_empty() {
                    "No specific strategy has been configured yet — use balanced, \
                     conservative judgment.".to_string()
                } else {
                    strategy
                };

                let session_id = agent.create_session("trading-tick", "trader", &task).await?;
                let result = agent.run_session(&session_id, "trader", 10).await?;

                Ok(ToolOutput::ok_with_meta(
                    result,
                    json!({ "session_id": session_id }),
                ))
            }
            other => Ok(ToolOutput::error(format!("unknown action: {other}"))),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db;
    use crate::messaging::MessagingManager;
    use crate::security::SandboxedFs;
    use crate::trash::TrashManager;
    use chrono::TimeZone;
    use std::sync::Arc;

    fn test_ctx() -> ToolContext {
        let base = std::env::temp_dir().join(format!("sa-tradingtest-{}", std::process::id()));
        let sandbox_dir = base.join("sandbox");
        let trash_dir = base.join("trash");
        std::fs::create_dir_all(&sandbox_dir).unwrap();
        std::fs::create_dir_all(&trash_dir).unwrap();

        let db = db::test_db();
        let db_read = db.clone();
        ToolContext {
            sandbox: SandboxedFs::new(sandbox_dir).unwrap(),
            db,
            db_read,
            http_client: reqwest::Client::new(),
            messaging: Arc::new(MessagingManager::new()),
            trash: Arc::new(TrashManager::new(&trash_dir).unwrap()),
        }
    }

    fn tool() -> RobinhoodTool {
        // Connection is never dialed by the tests below — none of them
        // exercise an action that calls mcp_client().
        RobinhoodTool::new(Arc::new(OnceLock::new()), "https://agent.robinhood.com/mcp/trading")
    }

    #[test]
    fn market_hours_weekday_open() {
        // Wed 2026-07-01 14:00 UTC = 10:00 ET (market open).
        let t = chrono::Utc.with_ymd_and_hms(2026, 7, 1, 14, 0, 0).unwrap();
        assert!(is_market_hours(t));
    }

    #[test]
    fn market_hours_weekday_before_open() {
        // 08:00 ET is before the 9:30 open.
        let t = chrono::Utc.with_ymd_and_hms(2026, 7, 1, 12, 0, 0).unwrap();
        assert!(!is_market_hours(t));
    }

    #[test]
    fn market_hours_weekday_after_close() {
        // 17:00 ET is after the 16:00 close.
        let t = chrono::Utc.with_ymd_and_hms(2026, 7, 1, 21, 0, 0).unwrap();
        assert!(!is_market_hours(t));
    }

    #[test]
    fn market_hours_weekend() {
        // Sat 2026-07-04, mid-day ET.
        let t = chrono::Utc.with_ymd_and_hms(2026, 7, 4, 15, 0, 0).unwrap();
        assert!(!is_market_hours(t));
    }

    #[test]
    fn find_tool_matches_by_keyword() {
        let infos = vec![
            McpToolInfo { name: "get_quote".into(), description: Some("Fetch a live price".into()), input_schema: json!({}) },
            McpToolInfo { name: "list_positions".into(), description: None, input_schema: json!({}) },
        ];
        // find_tool takes &McpClient, so exercise the matching logic directly
        // against the same haystack it builds instead of requiring a live client.
        let haystack = |t: &McpToolInfo| format!("{} {}", t.name, t.description.as_deref().unwrap_or("")).to_lowercase();
        assert!(["quote", "price"].iter().any(|k| haystack(&infos[0]).contains(k)));
        assert!(["position"].iter().any(|k| haystack(&infos[1]).contains(k)));
        assert!(!["quote", "price"].iter().any(|k| haystack(&infos[1]).contains(k)));
    }

    #[test]
    fn build_symbol_args_uses_schema_property_name() {
        let tool = McpToolInfo {
            name: "get_quote".into(),
            description: None,
            input_schema: json!({"type": "object", "properties": {"ticker": {"type": "string"}}}),
        };
        assert_eq!(RobinhoodTool::build_symbol_args(&tool, "AAPL"), json!({"ticker": "AAPL"}));
    }

    #[test]
    fn build_symbol_args_falls_back_to_symbol() {
        let tool = McpToolInfo { name: "get_quote".into(), description: None, input_schema: json!({}) };
        assert_eq!(RobinhoodTool::build_symbol_args(&tool, "AAPL"), json!({"symbol": "AAPL"}));
    }

    #[tokio::test]
    async fn watchlist_add_list_remove() {
        let ctx = test_ctx();
        let t = tool();

        let add = t
            .execute(json!({"action": "watchlist_add", "symbol": "aapl"}), &ctx)
            .await
            .unwrap();
        assert!(add.success);
        assert!(add.output.contains("AAPL"));

        let list = t.execute(json!({"action": "watchlist_list"}), &ctx).await.unwrap();
        assert!(list.success);
        assert!(list.output.contains("AAPL"));

        let remove = t
            .execute(json!({"action": "watchlist_remove", "symbol": "AAPL"}), &ctx)
            .await
            .unwrap();
        assert!(remove.success);
        assert!(remove.output.contains("Removed"));
    }

    #[tokio::test]
    async fn paper_order_requires_fields() {
        let ctx = test_ctx();
        let t = tool();
        let r = t
            .execute(json!({"action": "paper_order", "symbol": "AAPL"}), &ctx)
            .await
            .unwrap();
        assert!(!r.success);
        assert!(r.output.contains("required"));
    }

    #[tokio::test]
    async fn paper_order_rejects_bad_side() {
        let ctx = test_ctx();
        let t = tool();
        let r = t
            .execute(
                json!({"action": "paper_order", "symbol": "AAPL", "side": "yolo", "qty": 1, "price": 100.0, "rationale": "test"}),
                &ctx,
            )
            .await
            .unwrap();
        assert!(!r.success);
        assert!(r.output.contains("buy"));
    }

    /// Structural safety guarantee: paper_order never calls mcp_client(),
    /// so it cannot reach the MCP server (or any network endpoint) even if
    /// the connection string points at a live Robinhood account.
    #[tokio::test]
    async fn paper_order_never_touches_the_network() {
        // A connection string that would hang/fail if ever dialed.
        let t = RobinhoodTool::new(Arc::new(OnceLock::new()), "http://192.0.2.1:1/unreachable");
        let ctx = test_ctx();
        let r = t
            .execute(
                json!({"action": "paper_order", "symbol": "AAPL", "side": "buy", "qty": 1, "price": 190.5, "rationale": "test"}),
                &ctx,
            )
            .await
            .unwrap();
        assert!(r.success);
        assert!(r.output.contains("simulated only"));
    }

    #[tokio::test]
    async fn unknown_action() {
        let ctx = test_ctx();
        let t = tool();
        let r = t.execute(json!({"action": "nope"}), &ctx).await.unwrap();
        assert!(!r.success);
        assert!(r.output.contains("unknown action"));
    }

    #[test]
    fn tool_metadata() {
        let t = tool();
        assert_eq!(t.name(), "trading");
        assert!(!t.description().is_empty());
        let schema = t.parameters_schema();
        assert!(schema["required"].as_array().unwrap().contains(&json!("action")));
    }
}
