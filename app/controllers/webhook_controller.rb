require 'line/bot'
require 'net/http'
require 'json'
require 'nokogiri'
# URLに簡単にアクセスできるようにするためのライブラリ
require 'open-uri'

class WebhookController < ApplicationController
  protect_from_forgery except: [:callback] # CSRF対策無効化

  def client
    @client ||= Line::Bot::Client.new { |config|
      config.channel_secret = ENV["LINE_CHANNEL_SECRET"]
      config.channel_token = ENV["LINE_CHANNEL_TOKEN"]
    }
  end

  def callback
    body = request.body.read

    signature = request.env['HTTP_X_LINE_SIGNATURE']
    unless client.validate_signature(body, signature)
      head 470
    end

    events = client.parse_events_from(body)
    events.each { |event|
      case event
      when Line::Bot::Event::Message
        case event.type
        when Line::Bot::Event::MessageType::Text

          # ユーザから送られてきたテキストを変数化
          artist_name = event.message['text'].strip

          if artist_name.include?("おすすめのアーティスト") || artist_name.include?("おすすめのバンド")
            message = get_my_recommendation
          else
            # Last.fmのAPIを叩いて類似アーティストの情報を取得
            similar_artists_data = get_similar_artists(artist_name)
            # 類似アーティストをそれぞれカルーセルテンプレートに当てはめる
            message = make_carousel(similar_artists_data)
          end

          # 完成したカルーセルテンプレートをユーザに送り返す
          response = client.reply_message(event['replyToken'], message)
          logger.debug(response.body)

        when Line::Bot::Event::MessageType::Image, Line::Bot::Event::MessageType::Video
          response = client.get_message_content(event.message['id'])
          tf = Tempfile.open("content")
          tf.write(response.body)
        end
      end
    }
    head :ok
  end

  private

  API_KEY = ENV["API_KEY"]
  URL_ROOT = 'http://ws.audioscrobbler.com/2.0/'
  ARTIST_LIMIT_NUM = 10
  TRACK_LIMIT_NUM = 3
  ERR_MESSAGE = "ごめん、アーティストが見つかんなかった💦"
  ARTIST_IMG_URL = "https://lastfm.freetls.fastly.net/i/u/174s/2a96cbd8b46e442fc41c2b86b821562f.png"
  IMG_BACK_GROUND_COLOR = "#FFFFFF"
  BUTTON_MESSAGE = "ここからさらにディグる"
  MAX_NUM_PER_ROW = 21
  ARTIST_IMG_URL_ROOT = 'https://www.last.fm/music/'
  MY_RECOMMENDED_ARTIST = [
    "ハヌマーン",
    "リーガルリリー",
    "tricot",
    "ぜったくん",
    "predawn",
    "ネクライトーキー",
    "604",
    "SPARK!!SOUND!!SHOW!!",
    "不可思議/wonderboy",
    "in the blue shirt",
    "DIALUCK",
    "HASAMI group",
    "小南泰葉",
    "さよならポエジー",
    "ドミコ",
    "GEZAN",
    "Age Factory",
    "ENTH",
    "teto",
    "ナードマグネット",
    "モーモールルギャバン",
    "andymori",
    "plenty",
    "タカナミ",
    "SHADOWS",
    "魔法少女になり隊",
    "Pa's Lam System",
    "CHAI"
  ]

  def get_my_recommendation
    text = MY_RECOMMENDED_ARTIST.sample
    message = {
      type: 'text',
      text: text
    }
    message
  end

  def get_similar_artists(artist_name)
    uri = URI.parse(URL_ROOT)
    uri.query = URI.encode_www_form({
      limit: ARTIST_LIMIT_NUM,
      autocorrect: 1,
      method: "artist.getsimilar",
      artist: artist_name,
      api_key: API_KEY,
      format: "json"
    })

    res = Net::HTTP.get_response(uri)
    JSON.parse(res.body.to_s)
  end

  def get_artist_toptracks(artist_name)
    uri = URI.parse(URL_ROOT)
    uri.query = URI.encode_www_form({
      autocorrect: 1,
      limit: TRACK_LIMIT_NUM,
      method: "artist.gettoptracks",
      artist: artist_name,
      api_key: API_KEY,
      format: "json"
    })

    res = Net::HTTP.get_response(uri)
    JSON.parse(res.body.to_s)
  end

  def make_toptracks_ranking(artist)
    artist_toptracks_data = get_artist_toptracks(artist["name"])

    top_tracks = artist_toptracks_data["toptracks"]["track"]

    top_tracks_ranking = top_tracks.each_with_object("").with_index {|(track, text), i|
      row = "#{i+1}: #{track["name"]}\n"

      # 曲名が一行あたり20文字以下になるよう調整（LINEのAPIの仕様上、textが60文字までしか入力できないから）
      if row.size >= MAX_NUM_PER_ROW
        row = "#{row.slice(0, MAX_NUM_PER_ROW-4)}…\n"
      end
      text << row
    }
    top_tracks_ranking
  end

  def make_carousel(similar_artists_data)
    # アーティストが検索に引っかからなかった場合、または関連するアーティストが存在しない場合
    if similar_artists_data.dig("similarartists", "artist", 0).nil?
      message = {
        type: 'text',
        text: ERR_MESSAGE
      }
      return message
    end

    similar_artists = similar_artists_data["similarartists"]["artist"]

    columns = similar_artists.each_with_object([]) {|artist, columns|
      top_tracks_ranking = make_toptracks_ranking(artist)

      # アーティストの画像URLを取得
      artist_image_url = scraping_artist_image(artist["name"].chomp)

      # youtube上でアーティスト名を検索したURL
      youtube_url = get_youtube_url(artist["name"])

      columns.push({
        thumbnailImageUrl: artist_image_url,
        imageBackgroundColor: IMG_BACK_GROUND_COLOR,
        title: artist["name"],
        text: top_tracks_ranking.chomp,
        actions: [
          {
            type: "uri",
            label: "YouTubeで検索",
            uri: youtube_url
          },
          {
            type: "message",
            label: BUTTON_MESSAGE,
            text: artist["name"]
          },
        ]
      })
    }

    message = {
      type: "template",
      altText: "this is a carousel template",
      template: {
        type: "carousel",
        columns: columns,
        imageAspectRatio: "rectangle",
        imageSize: "cover"
      }
    }

    message
  end

  def scraping_artist_image(artist_name)
    url = ARTIST_IMG_URL_ROOT + artist_name.gsub(/[\s　]/, '+')
    url = URI.encode(url)

    charset = nil

    html = open(url) do |f|
        charset = f.charset
        f.read
    end

    doc = Nokogiri::HTML.parse(html, nil, charset)
    artist_image_url = doc.xpath('//*[@id="mantle_skin"]/header/div[1]/div[1]/div[1]')&.attribute('content')
    artist_image_url.to_s
  end

  def get_youtube_url(artist_name)
    'https://www.youtube.com/results?search_query=' + artist_name.gsub(/[\s　]/, '+')
  end

end
