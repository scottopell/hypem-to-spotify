require 'bundler/setup'
Bundler.require(:default, :test, :development)

module Tty extend self
  def blue; bold 34; end
  def green; bold 32; end
  def white; bold 39; end
  def red; underline 31; end
  def reset; escape 0; end
  def bold n; escape "1;#{n}" end
  def underline n; escape "4;#{n}" end
  def escape n; "\033[#{n}m" if STDOUT.tty? end
  def warn s; puts "#{red}#{s}#{reset}" end
end

DEFAULT_DELAY = 3

options = {}
OptionParser.new do |opts|
  opts.banner = "Usage: example.rb [options]"

  opts.on("-v", "--[no-]verbose", "Run verbosely") do |v|
    options[:verbose] = v
  end

  opts.on('-h', '--update-hypem', 'Update hypem liked tracks') do |h|
    options[:update_hypem] = h
  end
  opts.on('-s', '--update-spotify', 'Update spotify playlists') do |s|
    options[:update_spotify] = s
  end
end.parse!

users = ['longscott']
client = Mongo::Client.new('mongodb://127.0.0.1:27017/hype')
Dotenv.load

def user_fav_url user, page=1
  "https://api.hypem.com/v2/users/#{user}/favorites?key=swagger&page=#{page}"
end

def get_all_users_fav_songs user, logging = false
  songs = []
  page = 1

  retry_delay = DEFAULT_DELAY * 2

  loop do
    response = HTTParty.get(user_fav_url(user, page))
    if logging
      puts "Requested page #{page}:"
      puts "  Response code: #{response.code}"
      puts "  Number of records: #{response.parsed_response.length}" if response.code == 200
    end
    if response.code == 403
      puts "!! |403| waiting #{retry_delay} seconds, then retrying page #{page}" if logging
      sleep retry_delay
      retry_delay *= 2
      next
    elsif response.code == 404
      puts "|404| end of liked songs reached, breaking..." if logging
      break
    end

    songs.push(*response.parsed_response)
    page += 1

    puts "Sleeping for #{DEFAULT_DELAY} seconds..." if logging
    sleep DEFAULT_DELAY
  end

  songs
end


def update_hypem! users, client, logging = false
  db_users = {}
  users.each do |user|
    songs = get_all_users_fav_songs user, logging

    if logging
      puts "#{user} has #{songs.length} liked songs:"
      songs.each do |entry|
        puts "#{entry["artist"]} - #{entry["title"]}"
      end
    end

    collection_tracks = client[:tracks]

    db_users[user] = { "name" => user, "loved_songs" => [] }

    songs.map! do |s|
      db_users[user]["loved_songs"].push({ itemid: s["itemid"],
                                           ts_loved: s["ts_loved"] })

      # parse out boolean remix and remix artist
      m = s["title"].match(/.+\(([^)]+)remix\)/i)
      s["is_remix"] = false
      if m && m.length == 2
        s["is_remix"] = true
        s["remix_artist"] = m[1]
      end

      # parse out featuring artists
      # examples:
      # You & Me feat. Eliza Doolittle (Flume Remix)
      # Cheap Sunglasses (feat. Matthew Koma)
      # Timber feat. Ke$ha
      artists = s["title"].split(/feat\.?/)
      if artists.length > 1
        # artists[1] could contain
        # Eliza Doolittle (Flume Remix)
        # Matthew Koma)
        # Ke$ha
        s["featured_artists"] = artists[1].split("(").first.split(")").first
      end

      s["clean_title"] = s["title"].split(/feat\.?/).first.split("(").first

      s["loved_by"] = [] if s["loved_by"].nil?
      s["loved_by"].push(user)
      s.delete("ts_loved")
      s
    end

    track_bulk_ops = []
    songs.each do |s|
      track_bulk_ops.push(
        update_one: {
          filter: { itemid: s["itemid"] } ,
          update: { '$set' => s },
          upsert: true
        }
      )
    end

    begin
      result = collection_tracks.bulk_write(track_bulk_ops, ordered: false)
    rescue Mongo::Error::BulkWriteError => e
      warn "Error inserting into mongo, see result"
      puts "Result:"
      ap e.result
      puts "Operations Attempted:"
      ap track_bulk_ops
    end
  end

  collection_users = client[:users]
  user_bulk_ops = []
  db_users.each do |username, document|
    user_bulk_ops.push(
      {
        update_one: {
          filter: { name: document["name"] } ,
          update: { '$set' => document },
          upsert: true
        }
      }
    )
  end

  begin
    result = collection_users.bulk_write(user_bulk_ops, ordered: false)
  rescue Mongo::Error::BulkWriteError => e
    warn "Error inserting into mongo, see result"
    puts "Result:"
    ap e.result
    puts "Operations Attempted:"
    ap user_bulk_ops
  end
end

def update_spotify! client
  RSpotify.authenticate(ENV["SPOTIFY_CLIENT_ID"], ENV["SPOTIFY_CLIENT_SECRET"])

  # Now you can access playlists in detail, browse featured content and more
  me = RSpotify::User.find(ENV["SPOTIFY_USER"])
  collection_tracks = client[:tracks]

  collection_tracks.find.limit(20).each do |track|
    query = "track:#{track["clean_title"]} #{track["remix_artist"]}" +
            " #{track["featured_artists"]} artist:#{track["artist"]}"
    result = RSpotify::Track.search(query).first
    if result
      name = result.name
      artist = result.artists.first.name

      puts "#{Tty.green}\tSpotify Result: \"#{name} by #{artist}\"#{Tty.reset}"
    end
  end

end

if options[:update_hypem]
  update_hypem! users, client, true
end

if options[:update_spotify]
  update_spotify! client
end

