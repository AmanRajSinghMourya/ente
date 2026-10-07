CREATE UNIQUE INDEX CONCURRENTLY notification_history_photos_storage_warning_once
    ON notification_history(user_id, template_id)
    WHERE left(template_id, 15) = 'photos_storage_';
