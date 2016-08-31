# hypem-to-spotify

The goal of this project is to allow one to mirror a user's "loved" songs
on hype machine to a spotify playlist.

## Usage
```sh
mongod --fork # or run this in another terminal or tmux/screen or whatever
git clone https://github.com/scottopell/hypem-to-spotify/
cd hypem-to-spotify
bundle install
ruby db_creation.rb
ruby server.rb # rerun 'ruby server.rb' for automatic restart during dev
open "http://localhost:4567"
```

![Web Interface](http://i.imgur.com/YCMFcer.png)

## Docker Usage
Docker is intended for production deployment (kinda).

Choose either `docker-compose` or the commands under "MANUAL INSTRUCTIONS"
below.
```sh
docker-compose up

# MANUAL INSTRUCTIONS
docker network create -d bridge hype_project
docker build -t hypem-to-spotify .
docker run \
  -p 27017:27017 \
  --network=hype_project \
  --name mongo-host \
  -d \
  mongo
docker run \
  -p 3000:3000 \
  --rm \
  --network=hype_project \
  --name=app \
  --env-file=.env \
  hypem-to-spotify
```


## What Works
- Scraping loved songs to mongodb
- Login with Spotify
- Runs hypem->spotify scraping and spotify searching in a background thread
- Add a hypem's user's fav tracks as spotify playlist

## What's left to do
- Polish
- come up with an intelligent way to handle updating an existing hypem mirrored
  list
