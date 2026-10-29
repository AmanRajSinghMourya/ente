use anyhow::{Result, ensure};
use ente_accounts::AccountsClient;

use crate::{
    api,
    args::{App, Options},
    output,
    vault::State,
};

fn client(selected: Option<&str>, app: App, options: &Options) -> Result<AccountsClient> {
    ensure!(
        !options.offline,
        "usage is not stored locally; this command requires network access"
    );
    let state = State::load()?;
    api::authenticated_client(&state.accounts[state.resolve(selected)?], app)
}

pub async fn photos(selected: Option<&str>, options: &Options) -> Result<()> {
    let details = client(selected, App::Photos, options)?
        .account_details()
        .await?;
    output::usage(&details, options.json)
}

pub async fn locker(selected: Option<&str>, options: &Options) -> Result<()> {
    let usage = client(selected, App::Locker, options)?
        .locker_usage()
        .await?;
    output::locker_usage(&usage, options.json)
}
