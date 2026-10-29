use ente_accounts::auth;
use ente_core::b64;
use serde::Serialize;
use serde_wasm_bindgen as swb;
use tsify::Tsify;
use wasm_bindgen::prelude::*;

#[cfg(feature = "prelogin")]
mod client;

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error(transparent)]
    Accounts(#[from] ente_accounts::Error),
    #[error(transparent)]
    Serde(#[from] swb::Error),
    #[error(transparent)]
    Input(#[from] tsify::Error),
}

impl Error {
    fn name(&self) -> Option<&'static str> {
        match self {
            Self::Accounts(ente_accounts::Error::InsufficientMemory) => Some("insufficient_memory"),
            Self::Accounts(ente_accounts::Error::IncorrectRecoveryKey) => {
                Some("incorrect_recovery_key")
            }
            Self::Accounts(ente_accounts::Error::Http(http)) if http.status_code() == Some(404) => {
                Some("session_expired")
            }
            _ => None,
        }
    }
}

impl From<Error> for JsValue {
    fn from(error: Error) -> Self {
        let value = crate::js_error(&error, error.name());
        if let Error::Accounts(ente_accounts::Error::Http(http)) = &error
            && let Some(status) = http.status_code()
        {
            let _ = js_sys::Reflect::set(&value, &"status".into(), &status.into());
        }
        value
    }
}

#[derive(Serialize, Tsify)]
#[serde(rename_all = "camelCase")]
pub struct GeneratedKek {
    pub key: String,
    pub salt: String,
    pub mem_limit: u64,
    pub ops_limit: u32,
}

impl From<auth::GeneratedKek> for GeneratedKek {
    fn from(generated: auth::GeneratedKek) -> Self {
        Self {
            key: b64::encode(&generated.key),
            salt: b64::encode(&generated.salt),
            mem_limit: generated.mem_limit,
            ops_limit: generated.ops_limit,
        }
    }
}

#[wasm_bindgen(js_name = authGenerateInteractiveKek)]
pub fn auth_generate_interactive_kek(
    password: &str,
) -> Result<<GeneratedKek as Tsify>::JsType, Error> {
    GeneratedKek::from(auth::generate_interactive_kek(password)?)
        .into_js()
        .map_err(Into::into)
}
