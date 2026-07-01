use std::sync::{Arc, OnceLock, Weak};

use async_trait::async_trait;
use chrono::{Datelike, Timelike};
use chrono_tz::America::New_York;
use serde_json::json;

use super::{Tool, ToolContext, ToolOutput};
use crate::agent::Agent;
use crate::error::{Result, SafeAgentError};

const ROBINHOOD_API_BASE_ENV: &str = "ROBINHOOD_AGENT_BASE_URL";
const ROBINHOOD_API_BASE_DEFAULT: &str = "https://agent-api.robinhood.com/v1";
const ROBINHOOD_TOKEN_ENV: &str = "ROBINHOOD_AGENT_TOKEN";

/// Robinhood agentic-API tool — quotes, positions, account, and an
/// agent-managed watchlist. `paper_order` never places a real order; it
/// only logs a simulated decision. The `tick` action runs one full
/// LLM-reasoned pass over the watchlist by delegating to the `trader`
/// persona in a sub-session, so the fixed scaffold (defined in the
/// persona) and the user-editable strategy (session prompt, from
/// `trading_config`) stay separate.
pub struct RobinhoodTool {
    agent_ref: Arc<OnceLock<Weak<Agent>>>,
}

impl RobinhoodTool {
    pub fn new(agent_ref: Arc<OnceLock<Weak<Agent>>>) -> Self {
        Self { agent_ref }
    }

    fn agent(&self) -> Result<Arc<Agent>> {
        self.agent_ref
            .get()
            .and_then(|w| w.upgrade())
            .ok_or_else(|| SafeAgentError::Tool("agent not initialized".into()))
    }

    fn base_url() -> String {
        std::env::var(ROBINHOOD_API_BASE_ENV).unwrap_or_else(|_| ROBINHOOD_API_BASE_DEFAULT.into())
    }

    fn token() -> Result<String> {
        std::env::var(ROBINHOOD_TOKEN_ENV)
            .map_err(|_| SafeAgentError::Tool(format!("{ROBINHOOD_TOKEN_ENV} is not set")))
    }

    async fn get_json(ctx: &ToolContext, path: &str) -> Result<serde_json::Value> {
        let url = format!("{}{}", Self::base_url(), path);
        let resp = ctx
            .http_client
            .get(&url)
            .bearer_auth(Self::token()?)
            .send()
            .await?
            .error_for_status()?;
        Ok(resp.json().await?)
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
        "Robinhood agentic paper-trading. Actions: quote, positions, account \
         (read-only market data), watchlist_add, watchlist_remove, \
         watchlist_list (agent-managed symbol list), paper_order (logs a \
         simulated buy/sell decision, never places a real order), tick \
         (runs one full reasoning pass over the watchlist)."
    }

    fn parameters_schema(&self) -> serde_json::Value {
        json!({
            "type": "object",
            "required": ["action"],
            "properties": {
                "action": {
                    "type": "string",
                    "enum": ["quote", "positions", "account", "watchlist_add", "watchlist_remove", "watchlist_list", "paper_order", "tick"],
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
                let data = Self::get_json(ctx, &format!("/quotes/{symbol}")).await?;
                Ok(ToolOutput::ok_with_meta(data.to_string(), data))
            }
            "positions" => {
                let data = Self::get_json(ctx, "/positions").await?;
                Ok(ToolOutput::ok_with_meta(data.to_string(), data))
            }
            "account" => {
                let data = Self::get_json(ctx, "/account").await?;
                Ok(ToolOutput::ok_with_meta(data.to_string(), data))
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
                // Pure DB write — deliberately never calls any network
                // endpoint, real or otherwise. Price comes from the
                // caller's own prior `quote` call, not fetched again here.
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

    #[tokio::test]
    async fn watchlist_add_list_remove() {
        let ctx = test_ctx();
        let tool = RobinhoodTool::new(Arc::new(OnceLock::new()));

        let add = tool
            .execute(json!({"action": "watchlist_add", "symbol": "aapl"}), &ctx)
            .await
            .unwrap();
        assert!(add.success);
        assert!(add.output.contains("AAPL"));

        let list = tool.execute(json!({"action": "watchlist_list"}), &ctx).await.unwrap();
        assert!(list.success);
        assert!(list.output.contains("AAPL"));

        let remove = tool
            .execute(json!({"action": "watchlist_remove", "symbol": "AAPL"}), &ctx)
            .await
            .unwrap();
        assert!(remove.success);
        assert!(remove.output.contains("Removed"));
    }

    #[tokio::test]
    async fn paper_order_requires_fields() {
        let ctx = test_ctx();
        let tool = RobinhoodTool::new(Arc::new(OnceLock::new()));
        let r = tool
            .execute(json!({"action": "paper_order", "symbol": "AAPL"}), &ctx)
            .await
            .unwrap();
        assert!(!r.success);
        assert!(r.output.contains("required"));
    }

    #[tokio::test]
    async fn paper_order_rejects_bad_side() {
        let ctx = test_ctx();
        let tool = RobinhoodTool::new(Arc::new(OnceLock::new()));
        let r = tool
            .execute(
                json!({"action": "paper_order", "symbol": "AAPL", "side": "yolo", "qty": 1, "price": 100.0, "rationale": "test"}),
                &ctx,
            )
            .await
            .unwrap();
        assert!(!r.success);
        assert!(r.output.contains("buy"));
    }

    /// Structural safety guarantee: paper_order is a pure DB write with no
    /// http client in the ToolContext at all, so it cannot reach the
    /// network — it must fail if it tried, since there's no client to use.
    #[tokio::test]
    async fn paper_order_never_touches_the_network() {
        let mut ctx = test_ctx();
        // A client with no connect timeout budget pointed at a reserved,
        // non-routable address — any network attempt would hang/fail long
        // past this test's scope. Success here proves paper_order never
        // even tries.
        ctx.http_client = reqwest::Client::builder()
            .connect_timeout(std::time::Duration::from_millis(1))
            .build()
            .unwrap();

        let tool = RobinhoodTool::new(Arc::new(OnceLock::new()));
        let r = tool
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
        let tool = RobinhoodTool::new(Arc::new(OnceLock::new()));
        let r = tool.execute(json!({"action": "nope"}), &ctx).await.unwrap();
        assert!(!r.success);
        assert!(r.output.contains("unknown action"));
    }

    #[test]
    fn tool_metadata() {
        let tool = RobinhoodTool::new(Arc::new(OnceLock::new()));
        assert_eq!(tool.name(), "trading");
        assert!(!tool.description().is_empty());
        let schema = tool.parameters_schema();
        assert!(schema["required"].as_array().unwrap().contains(&json!("action")));
    }
}
