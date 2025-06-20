fx_version 'cerulean'
game 'gta5'


shared_script '@es_extended/imports.lua'

client_scripts {
    'client.lua'
}

server_scripts {
    'server.lua',
}

ui_page 'nui/index.html'

files {
    'nui/index.html',
    'data/audioexample_sounds.dat54.rel',
    'audiodirectory/custom_sounds.awc',
}

data_file 'AUDIO_WAVEPACK' 'audiodirectory'
data_file 'AUDIO_SOUNDDATA' 'data/audioexample_sounds.dat'
