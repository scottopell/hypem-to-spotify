module DBHelpers
  def self.create!
    # track document
    #{
    #              "itemid" => "2hn7f",
    #              "artist" => "Popeska",
    #               "title" => "I Believe",
    #          "dateposted" => 1470252496,
    #              "siteid" => 3488,
    #            "sitename" => "IHEARTCOMIX",
    #             "posturl" => "http://iheartcomix.com/tracks-of-the-week-3/",
    #              "postid" => 2985093,
    #         "loved_count" => 2381,
    #        "posted_count" => 5,
    #           "thumb_url" => "http://static.hypem.net/thumbs_new/85/2985093.jpg",
    #    "thumb_url_medium" => "http://static.hypem.net/thumbs_new/85/2985093_120.jpg",
    #     "thumb_url_large" => "http://static.hypem.net/thumbs_new/e2/2983138_500.jpg",
    #                "time" => 314,
    #         "description" => "It’s been pretty difficult keeping up with ",
    #         "itunes_link" => "http://hypem.com/go/itunes_search/Popeska",
    #      "spotify_result" => "6TJmQnO44YE5BtTxH8pop1",
    #   "no_spotify_result" => 1471194907,
    #            "loved_by" => ["longscott", "otheruser"]
    #}
    # user document
    #{
    #          "name" => "longscott",
    #          "loved_songs" => [
    #            { itemid: "2hn7f",
    #              ts_loved: 1470075636
    #            ]
    #}
    require 'mongo'

    client = Mongo::Client.new('mongodb://127.0.0.1:27017/hype')
    client[:tracks].drop
    client[:users].drop

    client[:users,
      {
        'validator' => {
          '$and' =>
            [
              { 'name'        => { '$type': "string" } },
              # mongodb has fucked up $type: array behavior so I'm just not going
              # to validate this field for now
              # { 'loved_songs' => { '$type': "array"  } }
            ]
        }
      }
    ].create

    client[:tracks,
      {
        'validator' => {
          '$and' =>
            [
              { 'itemid'           => { '$type':  "string" } } ,
              { 'artist'           => { '$type':  "string" } } ,
              { 'title'            => { '$type':  "string" } } ,
              { 'title'            => { '$type':  "string" } } ,
              { 'dateposted'       => { '$type':  "int"    } } ,
              { 'siteid'           => { '$type':  "int"    } } ,
              { 'sitename'         => { '$type':  "string" } } ,
              { 'posturl'          => { '$type':  "string" } } ,
              { 'postid'           => { '$type':  "int"    } } ,
              { 'loved_count'      => { '$type':  "int"    } } ,
              { 'posted_count'     => { '$type':  "int"    } } ,
              { 'thumb_url'        => { '$regex': /^http:/ } } ,
              { 'time'             => { '$type':  "int"    } } ,
              { 'description'      => { '$type':  "string" } } ,
              { 'itunes_link'      => { '$regex': /^http:/ } } ,
              { 'is_remix'         => { '$type':  "bool"   } } ,
              # mongodb has fucked up $type: array behavior so I'm just not going
              # to validate this field for now
              #{ 'loved_by'         => { '$type': "array"   } }
            ],
          '$or' =>
            [
              # https://jaihirsch.github.io/straw-in-a-haystack/mongodb/2015/12/04/mongodb-document-validation/
              # so if you have a pair of validators within an "or" construct
              # with one specifying type or regex or some query operator
              # and the other specifying "exists => false", then this semantically
              # means its optional, but if it exists it must match the query
              # operator.
              #
              # The problem with this is that when you want to make more than one
              # field optional (but valid), then you really can't. Consider below,
              # only one of these has to be true, so if thumb_url_medium is missing,
              # then that satisfies this condition, so thumb_url_large can contain
              # anything at all.
              #
              # I'm leaving this in here because it doesn't hurt anything and maybe
              # some day I'll come back and fix it.
              { 'thumb_url_medium'   => { '$regex': /^http:/ } } ,
              { 'thumb_url_medium'   => { 'exists': false    } } ,
              { 'thumb_url_large'    => { '$regex': /^http:/ } } ,
              { 'thumb_url_large'    => { 'exists': false    } } ,
              { 'no_spotify_results' => { '$type':  "int"    } } ,
              { 'no_spotify_results' => { 'exists':  false   } } ,
              { 'spotify_result'     => { '$type':  "string" } } ,
              { 'spotify_result'     => { 'exists':  false   } } ,
            ]

        }
      }
    ].create

    client[:tracks].indexes.create_one( { :itemid => 1 }, unique: true )
  end
end
