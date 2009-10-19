require 'uri'
require 'json' unless defined? ActiveSupport
require 'mq'
require 'bunny'
require 'minion/handler'

module Minion
	extend self

	def enqueue(jobs, data = {})
		## jobs can be one or more jobs
		if jobs.respond_to? :shift
			queue = jobs.shift
			data["next_job"] = jobs unless jobs.empty?
		else
			queue = jobs
		end

		log "send: #{queue}:#{data.to_json}"
		bunny.queue(queue, :durable => true, :auto_delete => false).publish(data.to_json)
	end

	def log(msg)
		@@logger ||= proc { |m| puts "#{Time.now} :minion: #{m}" }
		@@logger.call(msg)
	end

	def error(&blk)
		@@error_handler = blk
	end

	def logger(&blk)
		@@logger = blk
	end

	def job(queue, options = {}, &blk)
		handler = Minion::Handler.new queue
		handler.when = options[:when] if options[:when]
		handler.unsub = lambda do
			log "unsubscribing to #{queue}"
			MQ.queue(queue).unsubscribe
		end
		handler.sub = lambda do
			log "subscribing to #{queue}"
			MQ.queue(queue).subscribe(:ack => true) do |h,m|
				return if AMQP.closing?
				begin
					log "recv: #{queue}:#{m}"

					args = decode_json(m)

					result = yield(args)

					next_job(args, result)
				rescue Object => e
					raise unless error_handler
					error_handler.call(e,queue,m,h)
				end
				h.ack
				check_all
			end
		end
		@@handlers ||= []
		at_exit { Minion.run } if @@handlers.size == 0
		@@handlers << handler
	end

	def decode_json(string)
		if defined? ActiveSupport
			ActiveSupport::JSON.decode string
		else
			JSON.load string
		end
	end

	def check_all
		@@handlers.each { |h| h.check }
	end

	def run
		log "Starting minion"

		Signal.trap('INT') { AMQP.stop{ EM.stop } }
		Signal.trap('TERM'){ AMQP.stop{ EM.stop } }

		EM.run do
			AMQP.start(amqp_config) do
				MQ.prefetch(1)
				check_all
			end
		end
	end

	private

	def amqp_url
		ENV["AMQP_URL"] || "amqp://guest:guest@localhost/"
	end

	def amqp_config
		uri = URI.parse(amqp_url)
		{
			:vhost => uri.path,
			:host => uri.host,
			:user => uri.user,
			:port => (uri.port || 5672),
			:pass => uri.password
		}
	rescue
		raise "invalid AMQP_URL: #{uri.inspect} (#{e})"
	end

	def new_bunny
		b = Bunny.new(amqp_config)
		b.start
		b
	end

	def bunny
		@@bunny ||= new_bunny
	end

	def next_job(args, response)
		queue = args.delete("next_job")
		enqueue(queue,args.merge(response)) if queue
	end

	def error_handler
		@@error_handler ||= nil
	end
end

