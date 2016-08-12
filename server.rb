require 'bundler/setup'
Bundler.require(:default, :test, :development)
require 'sinatra'
require 'sinatra/cookies'

require 'open-uri'
require 'base64'
require 'uri'

client = Mongo::Client.new('mongodb://127.0.0.1:27017/hype')
track_collection = client[:tracks]
user_collection = client[:users]

Dotenv.load

SPOTIFY_REDIRECT_PATH = '/auth/spotify/callback'
SPOTIFY_REDIRECT_URI = "http://localhost:4567#{SPOTIFY_REDIRECT_PATH}"

# http://www.sinatrarb.com/faq.html#sessions
enable :sessions

configure :development do
  use BetterErrors::Middleware
  BetterErrors.application_root = __dir__
end


get '/' do
  @tracks = track_collection.find.sort(loved_count: -1)
  @users  = user_collection.find
  @user = spotify_user

  haml :index
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
      # ap response.parsed_response
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

  RSpotify::User.new(session[:spotify_hash])
end
