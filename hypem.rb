require 'awesome_print'
require 'optparse'
require 'httparty'
require 'mongo'
require 'json'
require 'pry'
require_relative "support"

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

users = ['longscott', 'glupin23', 'therealpunit']
client = Mongo::Client.new('mongodb://127.0.0.1:27017/hype')

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
  session = Support.initialize_spotify!
  username = Support.prompt("Please enter a username", "burgestrand")
  user_link = "spotify:user:#{username}"
  link = Spotify.link_create_from_string(user_link)

  if link.null?
    $logger.error "#{user_link} was apparently not parseable as a Spotify URI. Aborting."
    abort
  end

  user = Spotify.link_as_user(link)
  $logger.info "Attempting to load #{user_link}. Waiting forever until successful."
  Support.poll(session) { Spotify.user_is_loaded(user) }

  display_name = Spotify.user_display_name(user)
  canonical_name = Spotify.user_canonical_name(user)
  $logger.info "User loaded: #{display_name}."

  $logger.info "Loading user playlists by loading their published container: #{canonical_name}."
  container = Spotify.session_publishedcontainer_for_user_create(session, canonical_name)

  $logger.info "Attempting to load container. Waiting forever until successful."
  Support.poll(session) { Spotify.playlistcontainer_is_loaded(container) }

  $logger.info "Container loaded. Loading playlists until no more are loaded for three tries!"

  container_size = 0
  previous_container_size = 0
  break_counter = 0

  loop do
    container_size = Spotify.playlistcontainer_num_playlists(container)
    new_playlists = container_size - previous_container_size
    previous_container_size = container_size
    $logger.info "Loaded #{new_playlists} more playlists."

    # If we have loaded no new playlists for 4 tries, we assume we are done.
    if new_playlists == 0
      break_counter += 1
      if break_counter >= 4
        break
      end
    end

    $logger.info "Loading…"
    5.times do
      Support.process_events(session)
      sleep 0.2
    end
  end

  $logger.info "#{container_size} published playlists for #{display_name} found. Loading each playlists and printing it."
  container_size.times do |index|
    type = Spotify.playlistcontainer_playlist_type(container, index)
    playlist = Spotify.playlistcontainer_playlist(container, index)
    Support.poll(session) { Spotify.playlist_is_loaded(playlist) }

    playlist_name = Spotify.playlist_name(playlist)
    num_tracks = Spotify.playlist_num_tracks(playlist)

    # Retrieving link for playlist:
    playlist_link = Spotify.link_create_from_playlist(playlist)
    link_string = if playlist_link.nil?
      "(no link)"
    else
      Spotify.link_as_string(playlist_link)
    end

    $logger.info "  (#{type}) #{playlist_name}: #{link_string} (#{num_tracks} tracks)"
  end
end

if options[:update_hypem]
  update_hypem! users, client, true
end

if options[:update_spotify]
  update_spotify! client
end

