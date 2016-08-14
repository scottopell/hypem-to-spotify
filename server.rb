require 'bundler/setup'
Bundler.require(:default, :test, :development)
require 'sinatra'
require 'sinatra/cookies'

require 'open-uri'
require 'base64'
require 'uri'

require_relative './hype_parser'

client = Mongo::Client.new('mongodb://127.0.0.1:27017/hype')

track_collection = client[:tracks]
user_collection  = client[:users]
job_collection   = client[:jobs]

$user = nil

Mongo::Logger.logger       = ::Logger.new('mongo.log')
Mongo::Logger.logger.level = ::Logger::DEBUG

Dotenv.load

SPOTIFY_REDIRECT_PATH = '/auth/spotify/callback'
SPOTIFY_REDIRECT_URI  = "http://localhost:4567#{SPOTIFY_REDIRECT_PATH}"

# http://www.sinatrarb.com/faq.html#sessions
enable :sessions

configure :development do
  use BetterErrors::Middleware
  BetterErrors.application_root = __dir__
end

Thread.new do
  begin
    loop do
      job_collection.find.each do |job|
        if !job["scrape_user"].nil?
          HypeParser.update_hypem! [job["username"]], client, false
          job_collection.delete_one("_id" => job["_id"])
        elsif !job["refresh_spotify_results"].nil?
          refresh_spotify_results client, job["itemids"]
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
  @per_page = (params[:per_page] || 5).to_i
  @page     = (params[:page] || 1).to_i

  @tracks = track_collection.find
    .sort(loved_count: -1)
    .limit(@per_page)
    .skip(@per_page * (@page - 1))

  @total_pages = (track_collection.count / @per_page.to_f).ceil

  @pending_users = job_collection.find.map{|job| job["username"] }

  @users  = user_collection.find
  @user = spotify_user

  haml :index
end

get '/hype_user' do
  @tracks = []
  @target_user = user_collection.find(name: params['user_name']).limit(1).first

  refresh_spotify_job = {
    "refresh_spotify_results" => true,
    "itemids" => []
  }

  @target_user["loved_songs"].each do |song|
    track = track_collection.find(itemid: song["itemid"]).limit(1).first
    if track["spotify_result"].nil? &&
       Time.at(track["no_spotify_results"]) < 1.week.ago

      refresh_spotify_job["itemids"] << song["itemid"]
    end
    @tracks << track
  end
  job_collection.insert_one refresh_spotify_job

  @track_id_string = @tracks
    .select{|t| !t["spotify_result"].nil? }
    .map{|t| t["spotify_result"]}
    .join(',')


  haml :user_page
end

post '/submit_user_job' do
  status = "job_submitted"
  if HypeParser.does_user_exist? params[:username]
    job_collection.insert_one scrape_user: true, username: params[:username]
  else
    status = "err_user-doesnt-exist"
  end

  redirect "/##{status}"
end

get SPOTIFY_REDIRECT_PATH do
  code = params[:code]
  state = params[:state]
  storedState = cookies[:stateKey]

  if state.nil? || state != storedState
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
      user = RSpotify::User.new options
      session[:spotify_hash] = user.to_hash
    end
  end
  redirect to('/')
end

get '/auth/spotify' do
  state = SecureRandom.hex
  cookies[:stateKey] = state

  scope = 'user-read-private user-read-email'
  redirect 'https://accounts.spotify.com/authorize?' +
           "response_type=code&" +
           "client_id=#{ENV['SPOTIFY_CLIENT_ID']}&" +
           "scope=#{scope}&" +
           "redirect_uri=#{URI.encode(SPOTIFY_REDIRECT_URI)}&" +
           "state=#{state}"
end

def spotify_user
  if session[:spotify_hash].nil?
    return nil
  end

  $user || RSpotify::User.new(session[:spotify_hash])
end

def refresh_spotify_results client, itemids, verbose=false
  track_collection = client[:tracks]
  tracks = []
  itemids.each do |itemid|
    track = track_collection.find(itemid: itemid).limit(1).first

    # spotify doesn't seem to like '&' or 'and' in queries
    and_regex = /(&|\band\b)/

    remix  = track["remix_artist"].nil?     ? "" : track["remix_artist"].gsub(and_regex, '')
    feat   = track["featured_artists"].nil? ? "" : track["featured_artists"].gsub(and_regex, '')
    artist = track["artist"].nil?           ? "" : track["artist"].gsub(and_regex, '')

    query = "track:#{track["clean_title"]}" +
            " #{remix} #{feat} artist:#{artist}"
    result = RSpotify::Track.search(query).first

    puts "Looking for #{Tty.blue}#{track["name"]}#{Tty.reset} by #{Tty.blue}#{track["artist"]}#{Tty.reset}" if verbose
    if result
      track["spotify_result"] = result.id
      track["no_spotify_results"] = nil

      puts "#{Tty.green}\tFound on Spotify: \"#{result.name} by #{result.artists.first.name}\"#{Tty.reset}" if verbose
    else
      track["no_spotify_results"] = Time.now.utc.to_i
      track["spotify_result"] = nil
      puts "#{Tty.red}\tNo Results#{Tty.reset}" if verbose
    end
    tracks << track
  end

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

  begin
    track_collection.bulk_write(track_bulk_ops, ordered: false)
  rescue Mongo::Error::BulkWriteError => e
    warn "Error inserting into mongo, see result"
    puts "Result:"
    ap e.result
    puts "Operations Attempted:"
    ap track_bulk_ops
  end
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

