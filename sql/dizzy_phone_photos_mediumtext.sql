-- Run once if gallery camera saves fail: data URLs need more than varchar(2048).
ALTER TABLE `dizzy_phone_photos` MODIFY COLUMN `image_url` mediumtext NOT NULL;
