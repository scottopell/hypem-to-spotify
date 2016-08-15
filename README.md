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
ruby server.rb # rerun 'ruby server.rb' for automatic restart during dev
open "http://localhost:4567"
```

![Web Interface](http://i.imgur.com/KXChnrQ.png)


## What Works
- Scraping loved songs to mongodb
- Login with Spotify
- Runs hypem->spotify scraping and spotify searching in a background thread
- Add a hypem's user's fav tracks as spotify playlist

## What's left to do
- Polish
- come up with an intelligent way to handle updating an existing hypem mirrored
  list
