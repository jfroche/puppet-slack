require 'puppet'
require 'yaml'
require 'faraday'
require 'json'
require 'uri'

Puppet::Reports.register_report(:slack) do
	desc 'Send notification of puppet run reports to Slack Messaging.'

	def compose(config, message)
		payload = {
			'channel'  => config[:slack_channel],
			'username' => config[:slack_botname],
			'icon_url' => config[:slack_iconurl],
			'text'     => message
		}
		JSON.generate(payload)
	end

	def process

		# setup
		configfile = File.join(Puppet.settings[:confdir], 'slack.yaml')
		unless File.readable?(configfile)
			msg = "Slack report config file #{configfile} is not readable."
			raise(Puppet::ParseError, msg)
		end
		config = YAML.load_file(configfile)
		slack_uri = URI.parse(config[:slack_url])
		user = ENV['SUDO_USER'] || ENV['USER'] || '(unknown)'
		File.write('/tmp/env', ENV.to_yaml)

		# filter
		#return if self.status == 'unchanged'
		#return if self.status == 'changed'
		status_icon = case self.status
									when 'changed' then ':sparkles:'
									when 'failed' then ':no_entry:'
									when 'unchanged' then ':white_check_mark:'
									end
		# Refer: https://slack.zendesk.com/hc/en-us/articles/202931348-Using-emoji-and-emoticons

		# construct message
		if config[:slack_puppetboard_url]
			pb_url = config[:slack_puppetboard_url].gsub(/:fqdn/, self.host)

			message = "#{status_icon} Puppet run for #{user}@<#{pb_url}|#{self.host}> #{self.status} at #{Time.now.asctime}."
		else
			message = "#{status_icon} Puppet run by #{user}@#{self.host} #{self.status} at #{Time.now.asctime}."
		end
		query_results =  Puppet::Util::Puppetdb.query_puppetdb("facts { certname = \"#{self.host}\" and (name = \"tier\" or name =\"subrole\" or name = \"role\") }")
		node_facts = {}
		query_results.each do | result |
		  node_facts[result['name']] = result['value']
		end
		facter_facts = %w[ tier role subrole ]
		important_facts = {
			:environment => self.environment,
			:runmode => Puppet.settings[:name],
			:noop => Puppet.settings[:noop],
		}.merge(facter_facts.inject({}) { |hash, key|
			hash[key] = if f = node_facts.fetch(key)
										f
									else
										'*unknown*'
									end
			hash
		})

		important_facts_keys = important_facts.keys

		fact_table = [
			"| " + important_facts_keys.map{|key| key.capitalize}.join(' | ') + ' |',
			"| " + important_facts_keys.map{|key| '---'}.join(' | ') + ' |',
			"| " + important_facts_keys.map{|key| important_facts[key]}.join(' | ') + ' |',
		]

		message = [
			message,
			"",
			fact_table
		].flatten.join("\n")

		Puppet.info "Sending status for #{self.host} to Slack."

		conn = Faraday.new(:url => slack_uri.scheme + '://' + slack_uri.host) do |faraday|
			faraday.request :url_encoded
			faraday.adapter Faraday.default_adapter
		end

		conn.post do |req|
			req.url slack_uri.path
			req.body = "payload=" + compose(config, message)
		end

	end
end
