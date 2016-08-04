require 'awesome_print'
require 'httparty'
require 'json'
require 'pry'

DEFAULT_DELAY = 3

users = ['longscott']

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

users.each do |user|
  songs = get_all_users_fav_songs user

  puts "#{user} has #{songs.length} liked songs:"
  songs.each do |entry|
    puts "#{entry["artist"]} - #{entry["title"]}"
  end

  # check if songs exist in DB
  # connect foreign key to username
  # persisting this will decrease load on hypem
end
