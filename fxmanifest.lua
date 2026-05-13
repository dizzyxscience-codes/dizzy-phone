fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'dizzy-phone'
author 'DizzyxScience'
description 'Phone for qb — Camera/Gallery uses screenshot-basic (start before this resource) or Config.CameraUploadUrl'
version '1.5.1'

shared_script 'config.lua'

client_script 'client/main.lua'

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/main.lua',
}

ui_page 'html/index.html'

files {
    'html/index.html',
    'html/style.css',
    'html/app.js',
}

dependencies {
    'qb-core',
    'oxmysql',
}

-- My Garage uses qb-garages exports + events when Config.EnablePhoneGarage is true (ensure qb-garages is started).
