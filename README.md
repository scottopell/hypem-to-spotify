# hypem-to-spotify

The goal of this project is to allow one to mirror a user's "loved" songs
on hype machine to a spotify playlist.

## Usage
```sh
mongod & # or run this in another terminal or tmux/screen or whatever
git clone https://github.com/scottopell/hypem-to-spotify/
cd hypem-to-spotify
bundle install
ruby db_creation.rb
ruby hypem.rb --update-hypem
ruby server.rb
open "http://localhost:4567"
```

![Web Interface](http://i.imgur.com/KXChnrQ.png)


## What Works
- Scraping loved songs to mongodb
- Debugging web interface (basically a sanity check for what's in the DB)

## What's left to do
- Search for these songs on spotify
- add all these songs to a playlist
