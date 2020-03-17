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
          api_key = ENV["API_KEY"]

          artist_name = event.message['text'].strip

          uri = URI.parse(URL_ROOT)
          uri.query = URI.encode_www_form({
            limit: 5,
            method: "artist.getsimilar",
            artist: artist_name,
            api_key: api_key,
            format: "json"
          })

          res = Net::HTTP.get_response(uri)
          data = JSON.parse(res.body.to_s)

          text = ""
          i = 1
          begin
            similar_artists = data["similarartists"]["artist"]
            similar_artists.each {|artist|
              text << "#{i}: " + artist["name"] + "\n"
              i += 1
            }
          rescue NoMethodError => e
            text << "検索に失敗しました. 正しいアーティスト名を入力してください."
          end

          if text.size == 0
            text << "検索に失敗しました. 正しいアーティスト名を入力してください."
          end

          message = {
            type: 'text',
            text: text.chomp
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
  URL_ROOT = 'http://ws.audioscrobbler.com/2.0/'

end
