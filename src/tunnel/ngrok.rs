use std::time::Duration;

use tokio::process::{Child, Command};
use tokio::sync::watch;
use tracing::{error, info, warn};

use crate::config::NgrokConfig;

#[derive(serde::Deserialize)]
struct NgrokTunnelsResponse {
    tunnels: Vec<NgrokTunnel>,
}

#[derive(serde::Deserialize)]
struct NgrokTunnel {
    public_url: String,
}

pub async fn start(
    config: &NgrokConfig,
    local_port: u16,
    url_tx: watch::Sender<Option<String>>,
) -> Option<Child> {
    let ngrok_bin = std::env::var("NGROK_BIN")
        .unwrap_or_else(|_| config.bin.clone());

    let authtoken = crate::secrets::var("NGROK_AUTHTOKEN").ok().or_else(|| {
        if config.authtoken.is_empty() {
            None
        } else {
            Some(config.authtoken.clone())
        }
    });

    let port = std::env::var("NGROK_PORT")
        .ok()
        .and_then(|p| p.parse::<u16>().ok())
        .unwrap_or(local_port);

    let inspect_addr = format!("127.0.0.1:{}", config.inspect_port);

    let mut cmd = Command::new(&ngrok_bin);
    cmd.arg("http")
        .arg(port.to_string())
        .arg("--log").arg("stderr")
        .arg("--log-format").arg("json");

    if let Some(ref token) = authtoken {
        cmd.arg("--authtoken").arg(token);
    }

    let domain = std::env::var("NGROK_DOMAIN")
        .ok()
        .filter(|d| !d.is_empty())
        .unwrap_or_else(|| config.domain.clone());

    if !domain.is_empty() {
        cmd.arg("--domain").arg(&domain);
    }

    cmd.stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::inherit());

    info!(
        ngrok_bin = %ngrok_bin,
        port,
        inspect_port = config.inspect_port,
        domain = %domain,
        "starting ngrok tunnel"
    );

    let child = match cmd.spawn() {
        Ok(c) => {
            info!(pid = ?c.id(), "ngrok process spawned");
            c
        }
        Err(e) => {
            error!(err = %e, bin = %ngrok_bin, "failed to spawn ngrok — tunnel disabled");
            return None;
        }
    };

    let api_url = format!("http://{inspect_addr}/api/tunnels");
    let poll_interval = Duration::from_secs(config.poll_interval_secs);

    tokio::spawn(async move {
        let client = reqwest::Client::builder()
            .timeout(Duration::from_secs(5))
            .build()
            .unwrap_or_default();

        tokio::time::sleep(Duration::from_secs(2)).await;

        let mut attempts = 0u32;
        loop {
            match client.get(&api_url).send().await {
                Ok(resp) => {
                    if let Ok(body) = resp.json::<NgrokTunnelsResponse>().await {
                        if let Some(t) = body.tunnels.into_iter()
                            .find(|t| t.public_url.starts_with("https://"))
                        {
                            let url = t.public_url;
                            if url_tx.send(Some(url.clone())).is_ok() {
                                info!(public_url = %url, "ngrok tunnel ready");
                            }
                        }
                    }
                    attempts = 0;
                }
                Err(e) => {
                    attempts += 1;
                    if attempts <= 5 {
                        warn!(
                            attempt = attempts,
                            err = %e,
                            "ngrok API not ready yet, retrying..."
                        );
                    } else if attempts == 6 {
                        error!(
                            err = %e,
                            "ngrok API unreachable after multiple attempts — \
                             check that ngrok is installed and NGROK_AUTHTOKEN is set"
                        );
                    }
                }
            }

            tokio::time::sleep(poll_interval).await;
        }
    });

    Some(child)
}
