# Production Deployments

This describes Ente's production deployment. It is specific to our infrastructure and is generally unnecessary for self-hosted instances.

## Overview

We run Museum's Docker image on Ubuntu hosts with Docker and manage it with systemd, following the [service pattern](../../../infra/services/README.md) used by the rest of our infrastructure.

- [server-release.yml](../../../.github/workflows/server-release.yml) builds and publishes the image.

- [museum.service](museum.service) runs the container directly; [museum.nginx.service](museum.nginx.service) runs it behind Nginx.

- `systemctl start|stop|status museum` manages the running image.

- [update-and-restart-museum.sh](update-and-restart-museum.sh) pulls the latest image and restarts the service.

## Installation

To bring up another Museum node, prepare the instance to run our services.

Set up [Promtail](../../../infra/services/promtail/README.md), [Prometheus and node-exporter](../../../infra/services/prometheus/README.md).

If running behind Nginx, install the [nginx](../../../infra/services/nginx/README.md) service.

Add credentials:

```sh
sudo mkdir -p /root/museum/credentials
sudo tee /root/museum/credentials/pst-service-account.json
sudo tee /root/museum/credentials/fcm-service-account.json
sudo tee /root/museum/credentials.yaml
```

Add billing data from the pricing-data repository:

```sh
scp /path/to/pricing-data/{us,in,black-friday}.json <instance>:

sudo mkdir -p /root/museum/data/billing
sudo mv *.json /root/museum/data/billing/
```

Add TLS credentials unless running behind Nginx:

```sh
sudo tee /root/museum/credentials/tls.cert
sudo tee /root/museum/credentials/tls.key
```

Copy the service definition and restart script to the new instance, then install them in their system locations.

```sh
# If using nginx
scp scripts/deploy/museum.nginx.service <instance>:museum.service
# otherwise
scp scripts/deploy/museum.service <instance>:

scp scripts/deploy/update-and-restart-museum.sh <instance>:

sudo install -o root -g root -m 0644 museum.service \
    /etc/systemd/system/museum.service && rm museum.service
sudo install -o root -g root -m 0755 update-and-restart-museum.sh \
    /usr/local/sbin/update-and-restart-museum.sh && rm update-and-restart-museum.sh
sudo systemctl daemon-reload
```

If running behind Nginx, install Museum's Nginx configuration with suitable rate limits:

```sh
scp scripts/deploy/museum.nginx.conf <instance>:

sudo mv museum.nginx.conf /root/nginx/conf.d
sudo systemctl reload nginx
```

## Starting

SSH into the instance and run:

```sh
sudo /usr/local/sbin/update-and-restart-museum.sh
```

## Rollback

The update script tags the currently running image as `museum-prod:previous` before pulling. To roll back:

```sh
sudo docker tag rg.fr-par.scw.cloud/ente/museum-prod:previous rg.fr-par.scw.cloud/ente/museum-prod:latest
sudo systemctl restart museum
```

> [!NOTE]
>
> This doesn't work if there are migrations!

To reset the local `latest` back to the registry image, run `sudo /usr/local/sbin/update-and-restart-museum.sh` again, or

```sh
sudo docker pull rg.fr-par.scw.cloud/ente/museum-prod:latest
```

## Photos storage emails

This cloud-only job skips instances classified as self-hosted by the existing
user-repository check. It uses the configured production SMTP sender.

The daily Photos storage email job targets free individual accounts whose
`users.creation_time` is at or after `photos-storage-emails.launch-time`. Set
one fixed RFC3339 UTC launch timestamp through `ENTE_PHOTOS_STORAGE_EMAILS_LAUNCH_TIME`
or the existing `museum.yaml` configuration:

```yaml
photos-storage-emails:
    launch-time: "<agreed RFC3339 UTC launch timestamp>"
```

The cutoff is the production activation time, selected once the deployment is
ready. Leave it unset until then. An unset value quietly skips the new emails.
Invalid configuration logs an error and skips the job; startup times never become
the cutoff. Preserve the selected timestamp across restarts and later deployments.

E1 (`photos_storage_90_percent`) is attempted once when Photos usage is at least
90%, including full accounts. E2 (`photos_storage_reminder`) is attempted once on
the first eligible daily scan at least 48 hours after E1's attempt. Ineligible
periods pause E2 without recording an event or resetting the clock. For example,
E1 on day 0, 85% usage on day 1, and 90% usage on day 3 results in E2 on day 3.
Upgrading and later returning to free follows the same rule, even weeks later.

Photos usage excludes Locker storage, including Locker trash. The allowance uses
active bonuses with the existing cap. Referral and signup bonuses remain free;
non-free plans and active paid-tier storage add-ons count as paid. Family plans,
expired free subscriptions, and accounts restricted from login without active
login grace do not qualify. Legacy full-storage warning history does not exclude
post-launch accounts from E1 or E2.

An expired login-grace marker also pauses E1/E2 when the terminal deletion row
has been removed. No attempt is recorded. The existing storage-warning job
restores the restriction or clears grace after recovery; clearing grace allows
pending E1/E2 to resume without resetting their clock.

Attempts are committed to `notification_history` before sending. Migration 149's
partial unique index prevents repeats across instances and restarts. Send failures
and crashes after the claim consume that event. Preserve these event IDs, attempt
history, and the original cutoff when extending this sequence.

The separate daily `storage_limit_exceeded` mailer targets only paid individual
accounts, regardless of signup date. It retains combined Photos and Locker usage,
strict usage greater than the usable allowance, and its separate history.
Paid self-hosted accounts remain eligible for the legacy warning.
Pre-cutoff free accounts qualify for neither flow. Free self-hosted accounts also
stop receiving the legacy warning; the new cloud-only flow does not replace it there.
Other storage-warning sequences remain independent; their existing login
restrictions and grace period still apply to this flow.

Deploy the migration and paid-only legacy mailer everywhere with the launch time
unset, then retire old processes. When ready to activate E1/E2, record one RFC3339
UTC timestamp and supply that same value on every instance. Setting the cutoff
before retiring old processes can expose free users to both flows.
