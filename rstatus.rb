require 'bundler'
Bundler.require

require_relative 'models/all'

module Sinatra
  module UserHelper

    # This incredibly useful helper gives us the currently logged in user. We
    # keep track of that by just setting a session variable with their id. If it
    # doesn't exist, we just want to return nil.
    def current_user
      return User.first(:id => session[:user_id]) if session[:user_id]
      nil
    end

    # This very simple method checks if we've got a logged in user. That's pretty
    # easy: just check our current_user.
    def logged_in?
      current_user != nil
    end

    # Our `admin_only!` helper will only let admin users visit the page. If
    # they're not an admin, we redirect them to either / or the page that we
    # specified when we called it.
    def admin_only!(opts = {:return => "/"})
      unless logged_in? && current_user.admin?
        flash[:error] = "Sorry, buddy"
        redirect opts[:return]
      end
    end

    # Similar to `admin_only!`, `require_login!` only lets logged in users access
    # a particular page, and redirects them if they're not.
    def require_login!(opts = {:return => "/"})
      unless logged_in?
        flash[:error] = "Sorry, buddy"
        redirect opts[:return]
      end
    end
  end

  helpers UserHelper
end

class Rstatus < Sinatra::Base

  set :port, 8088


  # The `PONY_VIA_OPTIONS` hash is used to configure `pony`. Basically, we only
  # want to actually send mail if we're in the production environment. So we set
  # the hash to just be `{}`, except when we want to send mail.
  configure :test do
    PONY_VIA_OPTIONS = {}
  end

  configure :development do
    PONY_VIA_OPTIONS = {}
  end

  # We're using [SendGrid](http://sendgrid.com/) to send our emails. It's really
  # easy; the Heroku addon sets us up with environment variables with all of the
  # configuration options that we need.
  configure :production do
    PONY_VIA_OPTIONS =  {
      :address        => "smtp.sendgrid.net",
      :port           => "25",
      :authentication => :plain,
      :user_name      => ENV['SENDGRID_USERNAME'],
      :password       => ENV['SENDGRID_PASSWORD'],
      :domain         => ENV['SENDGRID_DOMAIN']
    }
  end

  use Rack::Session::Cookie, :secret => ENV['COOKIE_SECRET']
  set :root, File.dirname(__FILE__)
  set :haml, :escape_html => true
  set :method_override, true

  require 'rack-flash'
  use Rack::Flash

  configure do
    if ENV['MONGOHQ_URL']
      MongoMapper.config = {ENV['RACK_ENV'] => {'uri' => ENV['MONGOHQ_URL']}}
      MongoMapper.database = ENV['MONGOHQ_DATABASE']
      MongoMapper.connect("production")
    else
      MongoMapper.connection = Mongo::Connection.new('localhost')
      MongoMapper.database = "rstatus-#{settings.environment}"
    end
  end

  helpers Sinatra::UserHelper
  helpers Sinatra::ContentFor

  helpers do
    [:development, :production, :test].each do |environment|
      define_method "#{environment.to_s}?" do
        return settings.environment == environment.to_sym
      end
    end
  end

  use OmniAuth::Builder do
    provider :twitter, ENV["CONSUMER_KEY"], ENV["CONSUMER_SECRET"]
    provider :facebook, ENV["APP_ID"], ENV["APP_SECRET"]
  end

  get '/' do
    if logged_in?
      @updates = current_user.timeline
      haml :dashboard
    else
      haml :index, :layout => false
    end
  end

  get '/home' do
    haml :index, :layout => false
  end

  get '/replies' do
    if logged_in?
      haml :replies
    else
      haml :index, :layout => false
    end
  end

  get '/auth/:provider/callback' do
    auth = request.env['omniauth.auth']
    unless @auth = Authorization.find_from_hash(auth)
      if User.first :username => auth['user_info']['nickname']
        #we have a username conflict!

        #let's store their oauth stuff so they don't have to re-login after
        session[:oauth_token] = auth['credentials']['token']
        session[:oauth_secret] = auth['credentials']['secret']

        session[:uid] = auth['uid']
        session[:provider] = auth['provider']
        session[:name] = auth['user_info']['name']
        session[:nickname] = auth['user_info']['nickname']
        session[:website] = auth['user_info']['urls']['Website']
        session[:description] = auth['user_info']['description']
        session[:image] = auth['user_info']['image']

        flash[:notice] = "Sorry, someone has that name."
        redirect '/users/new'
        return
      else
        @auth = Authorization.create_from_hash(auth, uri("/"), current_user)
      end
    end

    session[:oauth_token] = auth['credentials']['token']
    session[:oauth_secret] = auth['credentials']['secret']
    session[:user_id] = @auth.user.id

    flash[:notice] = "You're now logged in."
    redirect '/'
  end

  get '/users/new' do
    haml :"users/new"
  end

  post '/users' do
    user = User.new params
    if user.save
      user.finalize("http://rstat.us") #uuuuuuuuugh

      #this is really stupid.
      auth = {}
      auth['uid'] = session[:uid]
      auth['provider'] = session[:provider]
      auth['user_info'] = {}
      auth['user_info']['name'] = session[:name]
      auth['user_info']['nickname'] = session[:nickname]
      auth['user_info']['urls'] = {}
      auth['user_info']['urls']['Website'] = session[:website]
      auth['user_info']['description'] = session[:description]
      auth['user_info']['image'] = session[:image]

      Authorization.create_from_hash(auth, uri("/"), user)

      flash[:notice] = "Thanks! You're all signed up with #{user.username} for your username."
      session[:user_id] = user.id
      redirect '/'
    else
      flash[:notice] = "Oops! That username was taken. Pick another?"
      redirect '/users/new'
    end
  end

  get "/logout" do
    session[:user_id] = nil
    flash[:notice] = "You've been logged out."
    redirect '/'
  end

  # show user profile
  get "/users/:slug" do
    @author = Author.first :username => params[:slug]
    haml :"users/show"
  end

  # subscriber receives updates
  # should be 'put', PuSH sucks at REST
  post "/feeds/:id.atom" do
    feed = Feed.first :id => params[:id]
    feed.update_entries(request.body.read, request.url, request.env['HTTP_X_HUB_SIGNATURE'])
  end

  post "/feeds" do
    feed_url = params[:url]

    if feed_url[0..3] = "feed"
      feed_url = "http" + feed_url[4..-1]
    end

    f = current_user.follow! feed_url
    unless f
      flash[:notice] = "The was a problem following #{params[:url]}."
      redirect "/users/#{@user.username}"
    else
      hub_url = f.hubs.first

      sub = OSub::Subscription.new(url("/feeds/#{f.id}.atom"), f.url, f.secret)
      sub.subscribe(hub_url, f.verify_token)

      name = f.author.username
      flash[:notice] = "Now following #{name}."
      redirect "/"
    end
  end

  # publisher will feed the atom to a hub
  # subscribers will verify a subscription
  get "/feeds/:id.atom" do
    feed = Feed.first :id => params[:id]
    if params['hub.challenge']
      sub = OSub::Subscription.new(request.url, feed.url, nil, feed.verify_token)

      # perform the hub's challenge
      respond = sub.perform_challenge(params['hub.challenge'])

      # verify that the random token is the same as when we
      # subscribed with the hub initially and that the topic
      # url matches what we expect
      verified = params['hub.topic'] == feed.url
      if verified and sub.verify_subscription(params['hub.verify_token'])
        if development?
          puts "Verified"
        end
        body respond[:body]
        status respond[:status]
      else
        if development?
          puts "Verification Failed"
        end
        # if the verification fails, the specification forces us to
        # return a 404 status
        status 404
      end
    else
      # TODO: Abide by headers that supply cache information
      body feed.atom(uri("/"))
    end
  end

  # user edits own profile
  get "/users/:username/edit" do
    @user = User.first :username => params[:username]
    if @user == current_user
      haml :"users/edit"
    else
      redirect "/users/#{params[:username]}"
    end
  end

  # user updates own profile
  put "/users/:username" do
    @user = User.first :username => params[:username]
    if @user == current_user
      @user.author.name    = params[:name]
      @user.author.email   = params[:email]
      @user.author.website = params[:website]
      @user.author.bio     = params[:bio]
      @user.author.save
      flash[:notice] = "Profile saved!"
      redirect "/users/#{params[:username]}"
      return
    else
      redirect "/users/#{params[:username]}"
    end
  end

  # an alias for the above route
  get "/users/:name/feed" do
    feed = User.first(:username => params[:name]).feed
    redirect "/feeds/#{feed.id}.atom"
  end

  # users can follow each other, and this route takes care of it!
  get '/users/:name/follow' do
    require_login! :return => "/users/#{params[:name]}/follow"

    @author = Author.first(:username => params[:name])
    redirect "/users/#{@author.username}" and return if @author.user == current_user

    #make sure we're not following them already
    if current_user.following? @author.feed.url
      flash[:notice] = "You're already following #{params[:name]}."
      redirect "/users/#{@author.username}"
      return
    end

    # then follow them!
    unless current_user.follow! @author.feed.url
      flash[:notice] = "The was a problem following #{params[:name]}."
      redirect "/users/#{@author.username}"
    else
      flash[:notice] = "Now following #{params[:name]}."
      redirect "/users/#{@author.username}"
    end
  end

  #this lets you unfollow a user
  get '/users/:name/unfollow' do
    require_login! :return => "/users/#{params[:name]}/unfollow"

    @author = Author.first(:username => params[:name])
    redirect "/users/#{@author.username}" and return if @author.user == current_user

    #make sure we're following them already
    unless current_user.following? @author.feed.url
      flash[:notice] = "You're not following #{params[:name]}."
      redirect "/users/#{@author.username}"
      return
    end

    #unfollow them!
    current_user.unfollow! @author.feed

    flash[:notice] = "No longer following #{params[:name]}."
    redirect "/users/#{@author.username}"
  end

  # this lets us see followers.
  get '/users/:name/followers' do
    @users = User.first(:username => params[:name]).followers
    haml :"users/list", :locals => {:title => "Followers"}
  end

  # This lets us see who is following.
  get '/users/:name/following' do
    @users = User.first(:username => params[:name]).following
    haml :"users/list", :locals => {:title => "Following"}
  end

  post '/updates' do
    u = Update.new(:text => params[:text], 
                   :author => current_user.author)

    # and entry to user's feed
    current_user.feed.updates << u
    current_user.feed.save
    current_user.save

    # tell hubs there is a new entry
    current_user.feed.ping_hubs

    flash[:notice] = "Update created."
    redirect "/"
  end

  get '/updates/:id' do
    @update = Update.first :id => params[:id]
    haml :"updates/show", :layout => :'updates/layout'
  end

  post '/signup' do
    u = User.create(:email => params[:email], 
                    :status => "unconfirmed")
    u.set_perishable_token

    if development?
      puts uri("/") + "confirm/#{u.perishable_token}"
    else
      Notifier.send_signup_notification(params[:email], u.perishable_token)
    end

    haml :"signup/thanks"
  end

  get "/confirm/:token" do
    @user = User.first :perishable_token => params[:token]
    # XXX: Handle user being nil (invalid confirmation)
    @username = @user.email.match(/^([^@]+?)@/)[1]

    @valid_username = false
    unless User.first :username => @username
      @valid_username = true
    end

    haml :"signup/confirm"
  end

  post "/confirm" do
    user = User.first :perishable_token => params[:perishable_token]
    user.username = params[:username]
    user.password = params[:password]
    user.status = "confirmed"
    user.author = Author.create(:username => user.username,
                                :email => user.email)
    user.finalize(uri("/"))
    user.save
    session[:user_id] = user.id.to_s

    flash[:notice] = "Thanks for signing up!"
    redirect '/'
  end

  get "/login" do
    haml :"login"
  end

  post "/login" do
    if user = User.authenticate(params[:username], params[:password])
      session[:user_id] = user.id
      flash[:notice] = "Login successful."
      redirect "/"
    else
      flash[:notice] = "The username or password you entered was incorrect"
      redirect "/login"
    end
  end

  delete '/updates/:id' do |id|
    update = Update.first :id => params[:id]

    if update.author == current_user.author
      update.destroy

      flash[:notice] = "Update Baleeted!"
      redirect "/"
    else
      flash[:notice] = "I'm afraid I can't let you do that, " + current_user.name + "."
      redirect back
    end
  end

  not_found do
    haml :'404', :layout => false
  end

  get "/hashtags/:tag" do
    @hashtag = params[:tag]
    @updates = Update.hashtag_search(@hashtag)
    haml :dashboard
  end

  get "/open_source" do
    haml :opensource
  end

  get "/follow" do
    haml :external_subscription
  end

  get "/js/app.js" do
    coffee :"coffee/app"
  end

  get "/js/home.js" do
    coffee :"coffee/home"
  end

  get "/js/update.js" do
    coffee :"coffee/update"
  end

  get "/js/updates.show.js" do
    coffee :"coffee/updates.show"
  end

end

