fx_version 'cerulean'
game 'gta5'
description 'Drone script'
version '1.2.6'


client_scripts {
    'config.lua',
    'client.lua'
}

server_scripts {
    'config.lua',
    'server.lua'
}

ui_page 'nui/index.html'

files {
    'nui/index.html',
    'nui/images/*.png',
    'nui/images/*.jpg',
    'nui/images/*.jpeg',
    'nui/images/*.svg',
    'nui/images/*.gif',
    'data/audioexample_sounds.dat54.rel',
    'audiodirectory/custom_sounds.awc',
}

data_file 'AUDIO_WAVEPACK' 'audiodirectory'
data_file 'AUDIO_SOUNDDATA' 'data/audioexample_sounds.dat'
