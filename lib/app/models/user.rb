# encoding: utf-8
class User
  include MongoMapper::Document
  include TwiMeido::Command
  plugin MongoMapper::Plugins::IdentityMap

  key :jabber_id,               String
  ensure_index :jabber_id
  key :last_said,               String
  key :request_token,           String
  key :request_token_secret,    String
  key :oauth_token,             String
  ensure_index :oauth_token
  key :oauth_token_secret,      String
  ensure_index :oauth_token_secret
  key :latitude_access_token,   String
  ensure_index :latitude_access_token
  key :latitude_created_at,     Time
  key :latitude_expires_in,     Integer
  key :latitude_refresh_token,  String
  ensure_index :latitude_refresh_token
  key :latitude_on,             Integer, :default => -1
  key :notification,            Array, :default => [:mention, :dm, :event]
  key :tracking_keywords,       Array
  key :tracking_keywords_world, Array
  key :tracking_user,           Array
  key :filter_keywords,         Array
  key :home_was_on,             Integer, :default => -1
  key :viewed_tweet_ids,        Array
  key :last_short_id,           Integer, :default => -1
  key :viewed_dm_ids,           Array
  key :last_dm_short_id,        Integer, :default => -1
  key :last_mention_id,         Integer
  key :last_dm_id,              Integer
  key :friends_ids,             Array
  key :blocked_user_ids,        Array
  key :no_retweets_ids,         Array
  timestamps!

  key :screen_name,             String
  key :twitter_user_id,         Integer
  ensure_index :twitter_user_id
  key :twitter_user_created_at, DateTime


  Notifications = [:home, :mention, :dm, :event, :track]
  MaxShortId = 'ZZ'.as_b26_to_i

  scope :authorized, where(:oauth_token.ne => nil, :oauth_token_secret.ne => nil)

  class << self
    def create_or_update_from_tweet(tweet)
      twitter_user =
        if tweet.user
          tweet.user
        elsif tweet.retweeted_status
          tweet.retweeted_status.user
        else
          nil
        end
      return unless twitter_user

      user = first_or_new(:twitter_user_id => twitter_user.id)
      user.update_attributes(twitter_user) if user.new? || user.updated_at < 1.day.ago
    end
  end

  def rest_api_client
    @rest_api_client ||= Grackle::Client.new(
      :ssl => true, :auto_append_ids => false,
      :headers => {"User-Agent" => "TwiMeido/#{TwiMeido::Version}"},
      :handlers => {:json => Grackle::Handlers::JSON2MashHandler.new}
    ).tap do |client|

      client.auth = {
        :type => :oauth,
        :consumer_key => AppConfig.twitter.consumer_key,
        :consumer_secret => AppConfig.twitter.consumer_secret,
        :token => oauth_token,
        :token_secret => oauth_token_secret
      }
    end
  end

  def check_latitude_expire
    if latitude_refresh_token && (latitude_created_at < (latitude_expires_in - 300).seconds.ago)
      uri = URI.parse 'https://accounts.google.com/o/oauth2/token'
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      req = Net::HTTP::Post.new uri.request_uri
      req.set_form_data({
        :client_id => AppConfig.google.client_id,
        :client_secret => AppConfig.google.client_secret,
        :refresh_token => latitude_refresh_token,
        :grant_type => 'refresh_token'
      })
      res = http.request(req)
      res.value
      res = Hashie::Mash.new(JSON.parse(res.body))
      update_attributes(
        :latitude_access_token => res.access_token,
        :latitude_created_at => Time.now,
        :latitude_expires_in => res.expires_in)
    end
  end

  def update_status!(data)
    if latitude_on == 1
      begin
        check_latitude_expire
        uri = URI.parse('https://www.googleapis.com/latitude/v1/currentLocation?granularity=best&key=' + AppConfig.google.api_key + '&access_token=' + latitude_access_token)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        res = http.request(Net::HTTP::Get.new(uri.request_uri))
        res.value
        latitude = JSON.parse(res.body)
        timestamp = Time.at(latitude['data']['timestampMs'].to_f / 1000)
        loc = {:lat => latitude['data']['latitude'], :lon => latitude['data']['longitude']} if timestamp > 1.hour.ago
      rescue Net::HTTPUnauthorized
        remove_latitude_token
      end
    end
    loc ||= {}

    rest_api_client.statuses.update! data.merge(loc)
  end

  def view_tweet!(tweet)
    Tweet.create(tweet) unless tweet.kind_of?(Tweet) || viewed_tweet_ids.include?(tweet.id)
    view_tweet_id!(tweet.id)
  end

  def view_tweet_id!(tweet_id)
    short_id = viewed_tweet_ids.index(tweet_id)
    return short_id if short_id

    self.last_short_id = -1 if self.last_short_id >= MaxShortId
    self.last_short_id += 1
    viewed_tweet_ids[self.last_short_id] = tweet_id
    save
    self.last_short_id
  end

  def viewed_tweet(short_id)
    Tweet.find(viewed_tweet_ids[short_id])
  end

  def fetch_tweet(short_id_or_tweet_id)
    if short_id_or_tweet_id.respond_to?(:is_valid_b26?) && short_id_or_tweet_id.is_valid_b26?
      short_id_or_tweet_id = short_id_or_tweet_id.as_b26_to_i
    else
      short_id_or_tweet_id = short_id_or_tweet_id.to_i
    end
    if short_id_or_tweet_id < 1000
      viewed_tweet(short_id_or_tweet_id)
    else
      Tweet.fetch(short_id_or_tweet_id)
    end
  end

  def viewed_dm(short_id)
    DirectMessage.find(viewed_dm_ids[short_id])
  end

  def fetch_dm(short_id_or_dm_id)
    if short_id_or_dm_id.respond_to?(:is_valid_b26?) && short_id_or_dm_id.is_valid_b26?
      short_id_or_dm_id = short_id_or_dm_id.as_b26_to_i
    else
      short_id_or_dm_id = short_id_or_dm_id.to_i
    end
    if short_id_or_dm_id < 1000
      viewed_dm(short_id_or_dm_id)
    else
      DirectMessage.fetch(short_id_or_dm_id)
    end
  end

  def view_dm!(dm)
    DirectMessage.create(dm) unless dm.kind_of?(DirectMessage) || viewed_dm_ids.include?(dm.id)
    view_dm_id!(dm.id)
  end

  def view_dm_id!(dm_id)
    short_id = viewed_dm_ids.index(dm_id)
    return short_id if short_id

    self.last_dm_short_id = -1 if self.last_dm_short_id >= MaxShortId
    self.last_dm_short_id += 1
    viewed_dm_ids[self.last_dm_short_id] = dm_id
    save
    self.last_dm_short_id
  end

  def authorized?
    !oauth_token.blank? && !oauth_token_secret.blank?
  end

  def initialize(attrs = {})
    super(rename_twitter_user_attributes(attrs))
  end

  def update_attributes(attrs = {})
    super(rename_twitter_user_attributes(attrs))
  end

  def home_common?(tweet)
    # NOTE: Twitter says that by supplying ``replies=all'', all @replies *by*
    #       followings are enabled.
    #       But actually all @replies *to* followings are enabled too.

    # The tweet was sent by myself?
    if tweet.user.id == twitter_user_id
      return true
    end
    # The tweet was sent by a friend?
    if !friends_ids.include? tweet.user.id
      return false
    end
    # The tweet isn't a reply or replied to a friend?
    if tweet.in_reply_to_user_id
      friends_ids.include? tweet.in_reply_to_user_id
    else
      true
    end
  end

  def mentioned_by?(tweet)
    result = tweet.entities.user_mentions.collect(&:id).include?(twitter_user_id)
    if !last_mention_id && result
      update_attributes(:last_mention_id => tweet.id)
    end
    result
  end

  def tracking?(tweet)
    tweet_text = tweet.text.downcase
    found = (tracking_keywords + tracking_keywords_world).select do |keyword|
      tweet_text.include?(keyword.downcase)
    end
    (tracking_user.include? tweet.user.screen_name.downcase) or !found.empty?
  end

  def filtered?(tweet)
    tweet_text = tweet.text
    tweet_text_dc = tweet_text.downcase
    tweet_source = tweet.source.downcase.gsub %r!\A<a .+?>(.+?)</a>\Z!, '\1'
    found = filter_keywords.select do |keyword|
      if keyword.start_with? 'source:'
        keyword.downcase == "source:#{tweet_source}"
      elsif keyword.start_with? 'link:'
        result = false
        if tweet.entities.present?
          tweet.entities.urls.each do |url|
            if url.expanded_url and url.expanded_url.include? keyword[5..-1]
              result = true
            end
          end
        end
        result
      elsif keyword.start_with? '?-i:'
        tweet_text.include? keyword[4..-1]
      else
        tweet_text_dc.include? keyword.downcase
      end
    end
    !found.empty?
  end

  def connect_user_streams
    if !tracking_user.empty? and notification.include? :track
      params = '?replies=all'
    else
      params = ''
    end
    stream = Twitter::JSONStream.connect(
      :host => 'userstream.twitter.com',
      :path => '/1.1/user.json' + params,
      :ssl => true,
      :user_agent => "TwiMeido/#{TwiMeido::Version}",
      :filters => tracking_keywords_world,
      #:params => params,
      :oauth => {
        :consumer_key    => AppConfig.twitter.consumer_key,
        :consumer_secret => AppConfig.twitter.consumer_secret,
        :access_key      => oauth_token,
        :access_secret   => oauth_token_secret
      }
    )

    stream.each_item do |item|
      begin
        item = JSON.parse(item)
        if item.respond_to?(:each_pair)
          item = Hashie::Mash.new(item)
          TwiMeido.current_user = self
          TwiMeido.process_user_stream(item)
        end
      rescue => error
        puts error.inspect
        puts error.backtrace.join("\n")
      end
    end

    stream.on_error do |message|
      puts "User streams error:\n#{message}"
    end

    stream.on_no_data do
      reconnect_user_streams
    end

    stream.on_unauthorized do
      remove_oauth_token
      @rest_polling_timer.cancel
    end

    stream.on_max_reconnects do |timeout, retries|
      puts "Max reconnects: timeout #{timeout}, #{retries} retries."
    end

    puts "#{Time.now.to_s :db} User streams for #{screen_name} connected"
    TwiMeido.user_streams[id] = stream
  end

  def reconnect_user_streams
    TwiMeido.user_streams[id].stop if TwiMeido.user_streams[id]
    connect_user_streams
    setup_rest_polling
  end

  def remove_oauth_token
    self.oauth_token = nil
    self.oauth_token_secret = nil
    save
  end

  def remove_latitude_token
    self.latitude_access_token = nil
    self.latitude_refresh_token = nil
    self.latitude_on = 0
    save
  end

  def setup_rest_polling
    @rest_polling_timer = EM.add_periodic_timer(300) do

      if notification.include?(:mention) || notification.include?(:dm)

        pull_rest_api = lambda {
          TwiMeido.current_user = self
          pull_mentions if notification.include?(:mention)
          pull_dms if notification.include?(:dm)
        }

        EM.defer(pull_rest_api)
      end
    end
    rest_update_ids = lambda {
      TwiMeido.current_user = self
      update_ids
    }

    EM.defer rest_update_ids
  end

  private
  def rename_twitter_user_attributes(attrs)
    renamed_attrs = attrs.dup
    renamed_attrs[:twitter_user_id] = renamed_attrs.delete(:id) if renamed_attrs.key? :id
    renamed_attrs[:twitter_user_created_at] = renamed_attrs.delete(:created_at) if renamed_attrs.key? :created_at
    renamed_attrs
  end

  def pull_mentions
    return unless last_mention_id

    tweets = rest_api_client.statuses.mentions_timeline?(
      :since_id => last_mention_id, :count => 200, :include_entities => true
    )
    return if tweets.empty?

    TwiMeido.process_rest_polling(tweets)
    update_attributes(:last_mention_id => tweets.first.id)

    sleep 5
  rescue => e
    puts "#{Time.now.to_s :db} #{screen_name}: #{e.method} #{e.request_uri} => #{e.status}"
  end

  def pull_dms
    return unless last_dm_id

    dms = rest_api_client.direct_messages?(
      :since_id => last_dm_id, :count => 200, :include_entities => true
    )
    return if dms.empty?

    prepared_dms = dms.map do |dm|
      Hashie::Mash.new(
        :direct_message => dm
      )
    end

    TwiMeido.process_rest_polling(prepared_dms)
    update_attributes(:last_dm_id => dms.first.id)

    sleep 5
  rescue => e
    puts "#{Time.now.to_s :db} #{screen_name}: #{e.method} #{e.request_uri} => #{e.status}"
  end

  def update_ids
    blocks = rest_api_client.blocks.ids? # fixme use cursor
    retweets = rest_api_client.friendships.no_retweets.ids?
    update_attributes(:blocked_user_ids => blocks.ids,
                      :no_retweets_ids => retweets)

    sleep 5
  rescue => e
    puts "#{Time.now.to_s :db} #{screen_name}: #{e.method} #{e.request_uri} => #{e.status}"
  end
end
