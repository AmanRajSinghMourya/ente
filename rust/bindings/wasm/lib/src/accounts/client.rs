use ente_accounts::lifecycle;
use serde::Deserialize;
use serde_wasm_bindgen as swb;
use tsify::{Ts, Tsify};
use wasm_bindgen::prelude::*;

use super::Error;

#[derive(Deserialize, Tsify)]
#[serde(rename_all = "camelCase")]
pub struct AccountsClientConfig {
    origin: String,
    client_package: String,
    #[tsify(optional)]
    client_version: Option<String>,
}

#[wasm_bindgen]
pub struct AccountsClient(ente_accounts::AccountsClient);

#[wasm_bindgen(js_name = createAccountsClient)]
pub fn create_accounts_client(config: Ts<AccountsClientConfig>) -> Result<AccountsClient, Error> {
    let config = config.to_rust()?;
    Ok(AccountsClient(ente_accounts::AccountsClient::new(
        ente_accounts::AccountsClientConfig {
            origin: config.origin,
            client_package: config.client_package,
            client_version: config.client_version,
            user_agent: None,
            auth_token: None,
        },
    )?))
}

#[wasm_bindgen(js_name = getTwoFactorRecovery, unchecked_return_type = "unknown")]
pub async fn get_two_factor_recovery(
    client: &AccountsClient,
    two_factor_type: &str,
    session_id: &str,
) -> Result<JsValue, Error> {
    let response = client
        .0
        .get_two_factor_recovery(
            session_id,
            swb::from_value(JsValue::from_str(two_factor_type))?,
        )
        .await?;
    swb::to_value(&response).map_err(Into::into)
}

#[wasm_bindgen(js_name = recoverTwoFactor, unchecked_return_type = "unknown")]
pub async fn recover_two_factor(
    client: &AccountsClient,
    two_factor_type: &str,
    session_id: &str,
    #[wasm_bindgen(unchecked_param_type = "unknown")] recovery_response: JsValue,
    recovery_key: &str,
) -> Result<JsValue, Error> {
    let response = lifecycle::recover_two_factor(
        &client.0,
        swb::from_value(JsValue::from_str(two_factor_type))?,
        session_id,
        &swb::from_value(recovery_response)?,
        recovery_key,
    )
    .await?;
    swb::to_value(&response).map_err(Into::into)
}
