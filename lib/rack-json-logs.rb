require 'rack-json-logs/version'
require 'rack-json-logs/pretty-printer.rb'
require 'json'
require 'stringio'
require 'socket'

module Rack

  # JsonLogs is a rack middleware that will buffer output, capture exceptions,
  # and log the entire thing as a json object for each request.
  #
  # Options are:
  #
  #   :reraise_exceptions
  #
  #     Whether to re-raise exceptions, or just respond with a standard JSON
  #     500 response.
  #
  #   :from
  #
  #     A string that describes where the request happened. This is useful if,
  #     for example, you want to log which server the request is from. Defaults
  #     to the machine's hostname.
  #
  #   :pretty_print
  #
  #     When set to true, this will pretty-print the logs, instead of printing
  #     the json. This is useful in development.
  #
  #   :print_options
  #
  #     When :pretty_print is set to true, these options will be passed to the
  #     pretty-printer. Run `json-logs-pp -h` to see what the options are.
  #
  #   :logstash_format
  #
  #     When :logstash_format is set, the log format is adjust to be the native
  #     format Logstash expects customized for Gravitant.
  #
  class JsonLogs

    def initialize(app, output=nil, options={})
      @app = app
      @options = {
        reraise_exceptions: false,
        pretty_print:       false,
        print_options:      {trace: true},
        logstash_json:    false,
      }.merge(options)
      @options[:from] ||= Socket.gethostname
      @output = output || $stdout
    end

    def clean_session_for_log(session)
      clean_session = session.to_hash.dup
      clean_session.delete("session_id")
      clean_session.delete("access_token")
      clean_session
    end



    def call(env)
      dev_mode = ENV['RACK_ENV'] == "development"

      start_time = Time.now
      $stdout, previous_stdout = (stdout_buffer = StringIO.new), $stdout unless dev_mode
      $stderr, previous_stderr = (stderr_buffer = StringIO.new), $stderr unless dev_mode

      logger = EventLogger.new(start_time)
      env = env.dup; env[:logger] = logger

      begin
        status, headers, response = @app.call(env)
      rescue Exception => e
        exception = e
      end

      # restore output IOs
      $stderr = previous_stderr unless dev_mode
      $stdout = previous_stdout unless dev_mode
      log = nil
      if @options[:logstash_json]
        request = Rack::Request.new(env)
        clean_session = clean_session_for_log(request.session)
        log_line = {
          "@timestamp" => start_time.iso8601,
          "@fields" => {
            hostname:        Socket.gethostname,
            host:            request.host,
            uri:             request.path_info,
            request_method:  request.request_method,
            body_bytes_sent: headers && headers['Content-Length'] || 0,
            http_user_agent: request.user_agent,
            remote_addr:     env['HTTP_X_FORWARDED_FOR'] || env['REMOTE_ADDR'],
            uid:             request.cookies['uid'],
            session:         clean_session,
            rack_env:        ENV['RACK_ENV']
          }
        }
        log = log_line["@fields"]
      else
          log_line = log = {
          time:     start_time.to_i
        }
      end
      log.merge!({
        duration: (Time.now - start_time).round(3),
        request:  "#{env['REQUEST_METHOD']} #{env['PATH_INFO']}",
        status:   status || 500,
        from:     @options[:from]
      })

      log[:stdout] = stdout_buffer.string unless dev_mode
      log[:stderr] = stderr_buffer.string unless dev_mode

      if logger.used
        log[:events] =  logger.events
        log[:all_events] = logger.all_events
      end
      if exception
        log[:exception] = {
          message:   exception.message,
          backtrace: exception.backtrace
        }
      end

      if @options[:pretty_print]
        JsonLogs.pretty_print(JSON.parse(log_line.to_json),
                            @output, @options[:print_options])
      else
        @output.puts(log_line.to_json)
      end
      @output.flush if @output.respond_to?("flush")

      raise exception if exception && @options[:reraise_exceptions]
      [status, headers, response]

    end

    # This class can be used to log arbitrary events to the request.
    #
    class EventLogger
      attr_reader :events, :used, :all_events

      def initialize(start_time)
        @events     = {}
        @used       = false
        @all_events = []
      end

      # Log an event of type `type` and value `value`.
      #
      def log(type, value)
        @used = true
        if type.is_a?(String)
          @all_events << type
          type_arr = type.split('.')
        else
          type_arr = type
          @all_events << type.join('.')
        end
        raise "Must have atleast one level of event in #{ type }" if type_arr.empty?
        the_event = @events
        type_arr[0..-2].each do |path_element|
          the_event[path_element] ||= {}
          the_event = the_event[path_element]
        end if type_arr.length > 1
        the_event[type_arr.last] = value
      end
    end
  end
end
