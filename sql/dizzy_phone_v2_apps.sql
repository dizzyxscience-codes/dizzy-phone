-- Run once if you already have dizzy_phone.sql applied.
CREATE TABLE IF NOT EXISTS `dizzy_phone_installed_apps` (
  `id` int NOT NULL AUTO_INCREMENT,
  `citizenid` varchar(50) NOT NULL,
  `app_id` varchar(32) NOT NULL,
  `installed_at` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  UNIQUE KEY `citizen_app` (`citizenid`,`app_id`),
  KEY `citizenid` (`citizenid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `dizzy_phone_social_posts` (
  `id` int NOT NULL AUTO_INCREMENT,
  `app_id` varchar(32) NOT NULL,
  `citizenid` varchar(50) NOT NULL,
  `author_phone` varchar(32) NOT NULL,
  `author_name` varchar(128) NOT NULL DEFAULT '',
  `body` varchar(500) NOT NULL,
  `created_at` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  KEY `app_created` (`app_id`,`created_at`),
  KEY `citizenid` (`citizenid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
