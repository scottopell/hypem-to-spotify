require 'bundler/setup'
Bundler.require(:default, :test, :development)
require 'sinatra'
require 'sinatra/cookies'

require 'open-uri'
require 'base64'
require 'uri'
require 'logger'

require_relative './hype_parser'

client = Mongo::Client.new('mongodb://127.0.0.1:27017/hype')

track_collection = client[:tracks]
user_collection  = client[:users]
job_collection   = client[:jobs]

$user = nil

Mongo::Logger.logger       = ::Logger.new('mongo.log')
Mongo::Logger.logger.level = ::Logger::DEBUG

Dotenv.load
RSpotify.authenticate(ENV["SPOTIFY_CLIENT_ID"], ENV["SPOTIFY_CLIENT_SECRET"])

SPOTIFY_REDIRECT_PATH = '/auth/spotify/callback'
SPOTIFY_REDIRECT_URI  = "http://localhost:4567#{SPOTIFY_REDIRECT_PATH}"

FLASH_TYPE_CLASS = {
  notice: 'alert-success',
  warning: 'alert-danger'
}

BATCH_SIZE = 100

# http://www.sinatrarb.com/faq.html#sessions
enable :sessions
set :session_secret, ENV["SESSION_SEED"]

use Rack::Flash

configure :development do
  use BetterErrors::Middleware
  BetterErrors.application_root = __dir__
end

hype_logger    = Logger.new("hype_parser.log")
spotify_logger = Logger.new("spotify_searcher.log")
Thread.new do
  begin
    loop do
      job_collection.find.sort("_id" => 1).each do |job|
        if !job["scrape_user"].nil?
          HypeParser.update_hypem! [job["username"]], client, hype_logger
          job_collection.delete_one("_id" => job["_id"])
        elsif !job["refresh_spotify_results"].nil?
          refresh_spotify_results client, job["itemids"], spotify_logger
          job_collection.delete_one("_id" => job["_id"])
        end
      end
      sleep 2.5
    end
  rescue StandardError => e
    $stderr << e.message
    $stderr << e.backtrace.join("\n")
  end
end

get '/' do

  @trending_tracks = track_collection.find
    .limit(10)
    .sort(loved_count: -1)

  @per_page = (params[:per_page] || 5).to_i
  @page     = (params[:page] || 1).to_i

  @tracks = track_collection.find
    .sort(loved_count: -1)
    .limit(@per_page)
    .skip(@per_page * (@page - 1))

  @total_pages = (track_collection.count / @per_page.to_f).ceil

  @pending_users = Hash.new 0
  job_collection.find.each do |job|
    @pending_users[job["username"]] += 1
  end

  @users = user_collection.find
  @user  = spotify_user

  haml :index
end

def pending_job? client, type, username
  job_collection = client[:jobs]
  job_collection
    .find({ type => true,
            "username" => username })
    .limit(1)
    .first
    .present?
end

def check_and_add_spotify_job client, username
  job_collection   = client[:jobs]
  user_collection  = client[:users]
  track_collection = client[:tracks]

  refresh_spotify_job = {
    "refresh_spotify_results" => true,
    "username" => username,
    "itemids" => []
  }
  return nil if pending_job?(client, "refresh_spotify_results", username)

  user = user_collection.find(name: username).limit(1).first
  return nil if user.nil?

  user["loved_songs"].each do |song|
    track = track_collection.find(itemid: song["itemid"]).limit(1).first
    next if track.nil?

    should_check_again = track["spotify_result"].nil?
    if !track["no_spotify_results"].nil?
      should_check_again = Time.at(track["no_spotify_results"]) < 1.week.ago
    end

    if should_check_again
      refresh_spotify_job["itemids"] << song["itemid"]
    end
  end

  return nil if refresh_spotify_job["itemids"].empty?

  job_collection.insert_one refresh_spotify_job
  return refresh_spotify_job
end

get '/hype_user' do
  @tracks = []
  @target_user = user_collection.find(name: params['user_name']).limit(1).first
  if @target_user.nil?
    redirect "/#error_no-such-user"
  end

  check_and_add_spotify_job client, @target_user["name"]

  @target_user["loved_songs"].each do |song|
    track = track_collection.find(itemid: song["itemid"]).limit(1).first
    @tracks << track if track.present?
  end

  # take 250 here because of spotify embed limitations (really limitations
  # on the length of the uri, roughly 6000 bytes, which is roughly 250 spotify
  # ids)
  @track_id_string = @tracks
    .select{|t| !t["spotify_result"].nil? }
    .take(250)
    .map{|t| t["spotify_result"]}
    .join(',')

  if params['confirm']
    if spotify_user.nil?
      flash[:notice] = "You need to login first"
    else
      playlist = spotify_user.create_playlist! "[HM] #{@target_user["name"]}"
      # TODO note the time this was created and the playlist ID
      # because at some point a user will "love" more songs and we want to be
      # able to add to the same playlist

      chunks = @tracks.each_slice(100).to_a

      chunks.each do |chunk|
        uris = chunk
          .select{|t| !t["spotify_result"].nil? }
          .map{|t| "spotify:track:#{t['spotify_result']}"}

        playlist.add_tracks! uris
      end
    end
  end

  @is_pending_job = pending_job? client,
                                 "refresh_spotify_results",
                                 @target_user["name"]

  @found_count = 0
  @not_found_count = 0
  @tracks.each do |track|
    if track["spotify_result"].present?
      @found_count += 1
    else
      @not_found_count += 1
    end
  end

  haml :user_page
end

post '/submit_user_job' do
  if HypeParser.does_user_exist? params[:username]
    job_collection.insert_one scrape_user: true,
                              username: params[:username]
    check_and_add_spotify_job client, params[:username]

    flash[:notice] = "Job submitted successfully"
  else
    flash[:alert] = "Error: user doesn't exist"
  end

  redirect '/'
end

get SPOTIFY_REDIRECT_PATH do
  code = params[:code]
  state = params[:state]
  storedState = cookies[:stateKey]

  if state.nil? || state != storedState
    flash[:warning] = "Error logging in, try again."
    redirect '/#error=state_mismatch'
  else
    cookies[:stateKey] = nil

    form_data = {
      'code' => code,
      'redirect_uri' => SPOTIFY_REDIRECT_URI,
      'grant_type' => 'authorization_code'
    }

    str = ENV['SPOTIFY_CLIENT_ID'] + ':' + ENV['SPOTIFY_CLIENT_SECRET']
    auth_string = Base64.strict_encode64 str
    headers = {
      'Authorization' => "Basic #{auth_string}"
    }

    auth_response = HTTParty.post 'https://accounts.spotify.com/api/token',
      query: form_data,
      headers: headers

    if auth_response.code == 200
      # ap auth_response.parsed_response
      #{
      #     "access_token" => "BQD6a8CKJC8YTa...O8J4E3IXeokL98298aI",
      #       "token_type" => "Bearer",
      #       "expires_in" => 3600,
      #    "refresh_token" => "AQA5-xU0OzWc6R...bqWfKAsw6IO4",
      #            "scope" => "user-read-email user-read-private"
      #}
      headers = {
        'Authorization' => "Bearer #{auth_response.parsed_response["access_token"]}"
      }

      info_response = HTTParty.get 'https://api.spotify.com/v1/me',
        headers: headers

      options = {
        'credentials' => auth_response.parsed_response,
        'info' => info_response.parsed_response
      }

      options['credentials']['token'] = options['credentials']['access_token']
      user = RSpotify::User.new options
      session[:spotify_hash] = user.to_hash
    end
  end
  flash[:notice] = "Logged in successfully"
  redirect to('#')
end

get '/auth/spotify' do
  state = SecureRandom.hex
  cookies[:stateKey] = state

  scope = 'user-read-private user-read-email playlist-modify-public playlist-modify-private'
  redirect 'https://accounts.spotify.com/authorize?' +
           "response_type=code&" +
           "client_id=#{ENV['SPOTIFY_CLIENT_ID']}&" +
           "scope=#{scope}&" +
           "redirect_uri=#{URI.encode(SPOTIFY_REDIRECT_URI)}&" +
           "state=#{state}"
end

get '/logout' do
  session.clear

  flash[:notice] = "Logged out successfully"
  redirect '/'
end

def spotify_user
  if session[:spotify_hash].nil?
    return nil
  end

  $user || RSpotify::User.new(session[:spotify_hash])
end

def refresh_spotify_results client, itemids, logger
  track_collection = client[:tracks]
  job_collection   = client[:jobs]

  slice_count = (itemids.count.to_f / BATCH_SIZE).ceil
  itemids.each_slice(BATCH_SIZE).with_index do |slice, slice_index|
    tracks = []
    logger.debug "Starting chunk #{slice_index} out of #{slice_count}"

    slice.each_with_index do |itemid, index|
      logger.debug "Processing item #{index} out of #{slice.count} (chunk #{slice_index})"
      track = track_collection.find(itemid: itemid).limit(1).first

      # spotify doesn't seem to like '&' or 'and' in queries
      and_regex = /(&|\band\b)/

      remix  = track["remix_artist"].nil?     ? "" : track["remix_artist"].gsub(and_regex, '')
      feat   = track["featured_artists"].nil? ? "" : track["featured_artists"].gsub(and_regex, '')
      artist = track["artist"].nil?           ? "" : track["artist"].gsub(and_regex, '')

      query = "track:#{track["clean_title"]}" +
              " #{remix} #{feat} artist:#{artist}"
      result = RSpotify::Track.search(query).first

      logger.debug "Looking for #{Tty.blue}#{track["name"]}#{Tty.reset} by #{Tty.blue}#{track["artist"]}#{Tty.reset}"
      if result
        track["spotify_result"] = result.id
        track["no_spotify_results"] = nil

        logger.debug "#{Tty.green}\tFound on Spotify: \"#{result.name} by #{result.artists.first.name}\"#{Tty.reset}"
      else
        track["no_spotify_results"] = Time.now.utc.to_i
        track["spotify_result"] = nil
        logger.debug "#{Tty.red}\tNo Results#{Tty.reset}"
      end
      tracks << track
    end

    logger.debug "Finished searching on spotify for chunk #{slice_index}"

    track_bulk_ops = []
    tracks.each do |t|
      track_bulk_ops.push(
        update_one: {
          filter: { itemid: t["itemid"] } ,
          update: { '$set' => t },
          upsert: true
        }
      )
    end

    logger.debug "Inserting songs for chunk #{slice_index} into DB..."

    begin
      track_collection.bulk_write(track_bulk_ops, ordered: false)
    rescue Mongo::Error::BulkWriteError => e
      logger.error "Error inserting into mongo, see result"
      logger.error "Result:"
      logger.error e.result.inspect
      logger.error "Operations Attempted:"
      logger.error track_bulk_ops.inspect
    end
    logger.debug "Successfully inserted songs for chunk #{slice_index}"

    begin
      operation = [ { "refresh_spotify_results" => true },
                    { "$pullAll" => { "itemids" => slice } } ]
      job_collection.update_many(*operation)
    rescue Mongo::Error => e
      logger.error "Error removing itemids in pullAll operation"
      logger.error "Result:"
      logger.error e.result.inspect
      logger.error "Operations Attempted:"
      logger.error operation.inspect
    end
  end
  logger.debug "Processed all chunks"
end

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

