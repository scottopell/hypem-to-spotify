require 'sinatra'
require 'mongo'
require 'awesome_print'

client = Mongo::Client.new('mongodb://127.0.0.1:27017/hype')
track_collection = client[:tracks]
user_collection = client[:users]


get '/' do
  @tracks = track_collection.find.sort(loved_count: -1)
  @users  = user_collection.find

  haml :index
end
