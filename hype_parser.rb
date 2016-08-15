require 'bundler/setup'
Bundler.require(:default, :test, :development)

module HypeParser
  DEFAULT_DELAY = 3

  def self.user_fav_url user, page=1
    "https://api.hypem.com/v2/users/#{user}/favorites?count=400&page=#{page}"
  end

  def self.does_user_exist? user
    response = HTTParty.get "https://api.hypem.com/v2/users/#{user}"
    !response.parsed_response["uid"].nil?
  end

  def self.get_all_users_fav_songs user, logger
    songs = []
    page = 1

    retry_delay = DEFAULT_DELAY * 2

    loop do
      response = HTTParty.get(user_fav_url(user, page))
      logger.debug "Requested page #{page}:"
      logger.debug "  Response code: #{response.code}"
      logger.debug "  Number of records: #{response.parsed_response.length}" if response.code == 200

      if response.code == 403
        logger.debug "!! |403| waiting #{retry_delay} seconds, then retrying page #{page}"
        sleep retry_delay
        retry_delay *= 2
        next
      elsif response.code == 404
        logger.debug "|404| end of liked songs reached, breaking..."
        break
      end

      songs.push(*response.parsed_response)
      page += 1

      logger.debug "Sleeping for #{DEFAULT_DELAY} seconds..."
      sleep DEFAULT_DELAY
    end

    songs
  end

  def self.update_hypem! users, client, logger
    db_users = {}
    users.each do |user|
      songs = get_all_users_fav_songs user, logger

      logger.debug "#{user} has #{songs.length} liked songs:"
      songs.each do |entry|
        logger.debug "#{entry["artist"]} - #{entry["title"]}"
      end

      collection_tracks = client[:tracks]

      db_users[user] = { "name" => user, "loved_songs" => [] }

      logger.debug "Processing songs..."
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

        unless s["title"].empty?
          s["clean_title"] = s["title"].split(/feat\.?/).first.split("(").first
        end

        s["loved_by"] = [] if s["loved_by"].nil?
        s["loved_by"].push(user)
        s.delete("ts_loved")
        s
      end
      logger.debug "Done processing songs"

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
        logger.error "Error inserting into mongo, see result"
        logger.error "Result:"
        logger.error e.result.inspect
        logger.error "Operations Attempted:"
        logger.error track_bulk_ops.inspect
      end
    end

    logger.debug "Songs inserted into DB"

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
      logger.error "Error inserting into mongo, see result"
      logger.error "Result:"
      logger.error e.result.inspect
      logger.error "Operations Attempted:"
      logger.error track_bulk_ops.inspect
    end
    logger.debug "User(s) inserted into DB"
  end
end
