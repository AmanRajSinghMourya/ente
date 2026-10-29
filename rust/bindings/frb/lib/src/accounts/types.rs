use ente_accounts::{AccountsClient as InnerClient, Error, lifecycle};
pub use ente_accounts::{
    auth::KeyAttributes,
    models::{TwoFactorAuthorizationResponse, TwoFactorRecoveryResponse, TwoFactorType},
};
use flutter_rust_bridge::frb;

#[frb(non_opaque)]
pub enum AccountsError {
    IncorrectRecoveryKey,
    SessionExpired,
    Other { message: String },
}

impl From<Error> for AccountsError {
    fn from(error: Error) -> Self {
        match error {
            Error::IncorrectRecoveryKey => Self::IncorrectRecoveryKey,
            Error::Http(ref http) if http.status_code() == Some(404) => Self::SessionExpired,
            _ => Self::Other {
                message: ente_core::error::chain(&error),
            },
        }
    }
}

#[frb(non_opaque)]
pub struct AccountsClientConfig {
    pub origin: String,
    pub client_package: String,
    pub client_version: Option<String>,
    pub user_agent: Option<String>,
}

#[frb(opaque)]
pub struct AccountsClient(pub(crate) InnerClient);

impl AccountsClient {
    pub async fn get_two_factor_recovery(
        &self,
        two_factor_type: TwoFactorType,
        session_id: String,
    ) -> Result<TwoFactorRecoveryResponse, AccountsError> {
        self.0
            .get_two_factor_recovery(&session_id, two_factor_type)
            .await
            .map_err(Into::into)
    }

    pub async fn recover_two_factor(
        &self,
        two_factor_type: TwoFactorType,
        session_id: String,
        recovery_response: TwoFactorRecoveryResponse,
        recovery_key: String,
    ) -> Result<TwoFactorAuthorizationResponse, AccountsError> {
        lifecycle::recover_two_factor(
            &self.0,
            two_factor_type,
            &session_id,
            &recovery_response,
            &recovery_key,
        )
        .await
        .map_err(Into::into)
    }
}

#[frb(mirror(TwoFactorType))]
pub enum _TwoFactorType {
    Totp,
    Passkey,
}

#[frb(mirror(TwoFactorRecoveryResponse))]
pub struct _TwoFactorRecoveryResponse {
    pub encrypted_secret: String,
    pub secret_decryption_nonce: String,
}

#[frb(mirror(TwoFactorAuthorizationResponse))]
pub struct _TwoFactorAuthorizationResponse {
    pub id: i64,
    pub key_attributes: KeyAttributes,
    pub encrypted_token: String,
}

#[frb(mirror(KeyAttributes))]
pub struct _KeyAttributes {
    pub kek_salt: String,
    pub encrypted_key: String,
    pub key_decryption_nonce: String,
    pub public_key: String,
    pub encrypted_secret_key: String,
    pub secret_key_decryption_nonce: String,
    pub mem_limit: u64,
    pub ops_limit: u32,
    pub master_key_encrypted_with_recovery_key: Option<String>,
    pub master_key_decryption_nonce: Option<String>,
    pub recovery_key_encrypted_with_master_key: Option<String>,
    pub recovery_key_decryption_nonce: Option<String>,
}
