require 'line/bot'
require 'net/http'
require 'json'

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

          # レベル2の実装（特定メッセージに対して、Last.fmのAPIをコールして、類似度上位５件のアーティスト名を応答する。https://www.last.fm/api/）
          artist_name = event.message['text'].strip

          data = get_similar_artists(artist_name)

          text = make_reply_text(data)

          message = {
            type: 'text',
            text: text
          }
          client.reply_message(event['replyToken'], message)
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
  LIMIT_NUM = 5
  ERR_MESSAGE = "アーティストが見つかりませんでした. "

  def get_similar_artists(artist_name)
    uri = URI.parse(URL_ROOT)
    uri.query = URI.encode_www_form({
      limit: LIMIT_NUM,
      autocorrect: 1,
      method: "artist.getsimilar",
      artist: artist_name,
      api_key: API_KEY,
      format: "json"
    })

    res = Net::HTTP.get_response(uri)
    return JSON.parse(res.body.to_s)
  end

  def make_reply_text(data)
    if data.nil? || (data["similarartists"]).nil?
      text = ERR_MESSAGE
    else
      similar_artists = data["similarartists"]["artist"]
      text = similar_artists.each_with_object("").with_index {|(artist, text), i|
        text << "#{i+1}: #{artist["name"]}\n"
      }
      if text.empty?
        text = ERR_MESSAGE
      end
    end
    return text.chomp
  end

end
