require "active_support/core_ext/object/blank"

module ActionDispatch
  class Request
    def cookie_jar
      env['action_dispatch.cookies'] ||= Cookies::CookieJar.build(self)
    end
  end

  # Cookies are read and written through ActionController#cookies.
  #
  # The cookies being read are the ones received along with the request, the cookies
  # being written will be sent out with the response. Reading a cookie does not get
  # the cookie object itself back, just the value it holds.
  #
  # Examples for writing:
  #
  #   # Sets a simple session cookie.
  #   cookies[:user_name] = "david"
  #
  #   # Sets a cookie that expires in 1 hour.
  #   cookies[:login] = { :value => "XJ-122", :expires => 1.hour.from_now }
  #
  # Examples for reading:
  #
  #   cookies[:user_name] # => "david"
  #   cookies.size        # => 2
  #
  # Example for deleting:
  #
  #   cookies.delete :user_name
  #
  # Please note that if you specify a :domain when setting a cookie, you must also specify the domain when deleting the cookie:
  #
  #  cookies[:key] = {
  #    :value => 'a yummy cookie',
  #    :expires => 1.year.from_now,
  #    :domain => 'domain.com'
  #  }
  #
  #  cookies.delete(:key, :domain => 'domain.com')
  #
  # The option symbols for setting cookies are:
  #
  # * <tt>:value</tt> - The cookie's value or list of values (as an array).
  # * <tt>:path</tt> - The path for which this cookie applies.  Defaults to the root
  #   of the application.
  # * <tt>:domain</tt> - The domain for which this cookie applies.
  # * <tt>:expires</tt> - The time at which this cookie expires, as a Time object.
  # * <tt>:secure</tt> - Whether this cookie is a only transmitted to HTTPS servers.
  #   Default is +false+.
  # * <tt>:httponly</tt> - Whether this cookie is accessible via scripting or
  #   only HTTP. Defaults to +false+.
  class Cookies
    HTTP_HEADER = "Set-Cookie".freeze
    TOKEN_KEY   = "action_dispatch.secret_token".freeze

    # Raised when storing more than 4K of session data.
    class CookieOverflow < StandardError; end

    class CookieJar < Hash #:nodoc:
      def self.build(request)
        secret = request.env[TOKEN_KEY]
        new(secret).tap do |hash|
          hash.update(request.cookies)
        end
      end

      def initialize(secret=nil)
        @secret = secret
        @set_cookies = {}
        @delete_cookies = {}
        super()
      end

      # Returns the value of the cookie by +name+, or +nil+ if no such cookie exists.
      def [](name)
        super(name.to_s)
      end

      # Sets the cookie named +name+. The second argument may be the very cookie
      # value, or a hash of options as documented above.
      def []=(key, options)
        if options.is_a?(Hash)
          options.symbolize_keys!
          value = options[:value]
        else
          value = options
          options = { :value => value }
        end

        value = super(key.to_s, value)

        options[:path] ||= "/"
        @set_cookies[key] = options
        @delete_cookies.delete(key)
        value
      end

      # Removes the cookie on the client machine by setting the value to an empty string
      # and setting its expiration date into the past. Like <tt>[]=</tt>, you can pass in
      # an options hash to delete cookies with extra data such as a <tt>:path</tt>.
      def delete(key, options = {})
        options.symbolize_keys!
        options[:path] ||= "/"
        value = super(key.to_s)
        @delete_cookies[key] = options
        value
      end

      # Returns a jar that'll automatically set the assigned cookies to have an expiration date 20 years from now. Example:
      #
      #   cookies.permanent[:prefers_open_id] = true
      #   # => Set-Cookie: prefers_open_id=true; path=/; expires=Sun, 16-Dec-2029 03:24:16 GMT
      #
      # This jar is only meant for writing. You'll read permanent cookies through the regular accessor.
      #
      # This jar allows chaining with the signed jar as well, so you can set permanent, signed cookies. Examples:
      #
      #   cookies.permanent.signed[:remember_me] = current_user.id
      #   # => Set-Cookie: discount=BAhU--848956038e692d7046deab32b7131856ab20e14e; path=/; expires=Sun, 16-Dec-2029 03:24:16 GMT
      def permanent
        @permanent ||= PermanentCookieJar.new(self, @secret)
      end

      # Returns a jar that'll automatically generate a signed representation of cookie value and verify it when reading from
      # the cookie again. This is useful for creating cookies with values that the user is not supposed to change. If a signed
      # cookie was tampered with by the user (or a 3rd party), an ActiveSupport::MessageVerifier::InvalidSignature exception will
      # be raised.
      #
      # This jar requires that you set a suitable secret for the verification on your app's config.secret_token.
      #
      # Example:
      #
      #   cookies.signed[:discount] = 45
      #   # => Set-Cookie: discount=BAhpMg==--2c1c6906c90a3bc4fd54a51ffb41dffa4bf6b5f7; path=/
      #
      #   cookies.signed[:discount] # => 45
      def signed
        @signed ||= SignedCookieJar.new(self, @secret)
      end

      def write(headers)
        @set_cookies.each { |k, v| ::Rack::Utils.set_cookie_header!(headers, k, v) }
        @delete_cookies.each { |k, v| ::Rack::Utils.delete_cookie_header!(headers, k, v) }
      end
    end

    class PermanentCookieJar < CookieJar #:nodoc:
      def initialize(parent_jar, secret)
        @parent_jar, @secret = parent_jar, secret
      end

      def []=(key, options)
        if options.is_a?(Hash)
          options.symbolize_keys!
        else
          options = { :value => options }
        end

        options[:expires] = 20.years.from_now
        @parent_jar[key] = options
      end

      def signed
        @signed ||= SignedCookieJar.new(self, @secret)
      end

      def method_missing(method, *arguments, &block)
        @parent_jar.send(method, *arguments, &block)
      end
    end

    class SignedCookieJar < CookieJar #:nodoc:
      MAX_COOKIE_SIZE = 4096 # Cookies can typically store 4096 bytes.
      SECRET_MIN_LENGTH = 30 # Characters

      def initialize(parent_jar, secret)
        ensure_secret_secure(secret)
        @parent_jar = parent_jar
        @verifier   = ActiveSupport::MessageVerifier.new(secret)
      end

      def [](name)
        if signed_message = @parent_jar[name]
          @verifier.verify(signed_message)
        end
      rescue ActiveSupport::MessageVerifier::InvalidSignature
        nil
      end

      def []=(key, options)
        if options.is_a?(Hash)
          options.symbolize_keys!
          options[:value] = @verifier.generate(options[:value])
        else
          options = { :value => @verifier.generate(options) }
        end

        raise CookieOverflow if options[:value].size > MAX_COOKIE_SIZE
        @parent_jar[key] = options
      end

      def method_missing(method, *arguments, &block)
        @parent_jar.send(method, *arguments, &block)
      end

    protected

      # To prevent users from using something insecure like "Password" we make sure that the
      # secret they've provided is at least 30 characters in length.
      def ensure_secret_secure(secret)
        if secret.blank?
          raise ArgumentError, "A secret is required to generate an " +
            "integrity hash for cookie session data. Use " +
            "config.secret_token = \"some secret phrase of at " +
            "least #{SECRET_MIN_LENGTH} characters\"" +
            "in config/application.rb"
        end

        if secret.length < SECRET_MIN_LENGTH
          raise ArgumentError, "Secret should be something secure, " +
            "like \"#{ActiveSupport::SecureRandom.hex(16)}\".  The value you " +
            "provided, \"#{secret}\", is shorter than the minimum length " +
            "of #{SECRET_MIN_LENGTH} characters"
        end
      end
    end

    def initialize(app)
      @app = app
    end

    def call(env)
      status, headers, body = @app.call(env)

      if cookie_jar = env['action_dispatch.cookies']
        cookie_jar.write(headers)
        if headers[HTTP_HEADER].respond_to?(:join)
          headers[HTTP_HEADER] = headers[HTTP_HEADER].join("\n")
        end
      end

      [status, headers, body]
    end
  end
end
