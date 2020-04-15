require "json"
require "http/client"
require "log"

require "dotenv"
require "discordcr"

backend = Log::IOBackend.new
Log.builder.bind "*", :info, backend

begin
  Dotenv.load
end

CARC_BASE = "https://carc.in"
LANGS     = {
  "crystal" => {"crystal", "0.34.0"},
  "cr"      => {"crystal", "0.34.0"},
  "ruby"    => {"ruby", "2.7.0"},
  "rb"      => {"ruby", "2.7.0"},
  "c"       => {"gcc", "6.3.1"},
}

TOKEN     = "Bot #{ENV["CARC_DISCORD_TOKEN"]}"
CLIENT_ID = ENV["CARC_DISCORD_CLIENT_ID"].to_u64
PREFIX    = ENV["CARC_PREFIX"]

default_headers = HTTP::Headers{
  "Content-Type" => "application/json",
  "User-Agent"   => "carc.in-discord",
}

client = Discord::Client.new(token: TOKEN, client_id: CLIENT_ID)
cache = Discord::Cache.new(client)

struct Run
  JSON.mapping(
    id: String,
    language: String,
    version: {type: String, nilable: true},
    code: String,
    stdout: String,
    stderr: String,
    exit_code: Int32,
    created_at: {type: Time, converter: Time::Format.new("%FT%TZ"), nilable: true},
    url: String,
    html_url: String,
    download_url: String
  )
end

struct Codeblock
  JSON.mapping(
    language: String,
    latest_known_version: String,
    code: String,
  )

  def initialize(@language, @latest_known_version, @code)
  end
end

def codeblock_from_message_content(message_content : String)
  codeblock_regex = /```(crystal|cr|ruby|rb|c)[\s\S]+```/m

  match = codeblock_regex.match message_content
  return unless match

  lines = match[0].lines
  return if lines.size < 2
  lines.pop

  language = LANGS[lines.shift.lchop "```"]?
  return unless language

  latest_known_version = language[1]
  language = language[0]
  code = lines.reduce { |acc, line| "#{acc}\n#{line}" }

  Codeblock.new language, latest_known_version, code
end

client.on_message_create do |message|
  mentions = Discord::Mention.parse message.content
  next if mentions.size != 1

  mention = mentions[0]

  if mention.is_a? Discord::Mention::User
    next if mention.id != CLIENT_ID
  else
    next
  end

  codeblock = codeblock_from_message_content message.content
  next unless codeblock

  version = codeblock.latest_known_version

  specified_version_regex = /(crystal|ruby|gcc)=(\d{1,3}\.\d{1,3}\.\d{1,3})/
  match = specified_version_regex.match message.content
  version = match[2] if match

  body = {
    "run_request" => {
      "language" => codeblock.language,
      "version"  => version,
      "code"     => codeblock.code,
    },
  }

  response = HTTP::Client.post "#{CARC_BASE}/run_requests", headers: default_headers, body: body.to_json.to_s

  if response.status_code != 200
    client.create_message message.channel_id, "Non-200 status code response from carc.in:\n```json\n#{response.body}\n```"
    next
  end

  body = JSON.parse response.body
  run = Run.from_json body["run_request"]["run"].to_json

  footer = Discord::EmbedFooter.new(
    text: "#{run.language} #{run.version} (exit code #{run.exit_code})"
  )

  colour = 6681127_u32
  colour = 16728128_u32 if run.exit_code != 0

  embed = Discord::Embed.new(
    title: "View on carc.in",
    url: run.html_url,
    footer: footer,
    colour: colour,
    timestamp: run.created_at
  )

  content = String.build do |string|
    string << "<@#{message.author.id}>\n"
    string << "**stdout**\n```\n#{run.stdout}\n```\n" if !run.stdout.empty?
    string << "**stderr**\n```\n#{run.stderr}\n```\n" if !run.stderr.empty?
  end

  reply = ""
  case content.size
  when 0
    reply = "_(there was no output)_"
  when .> 2000
    reply = "_message too long (#{content.size} / 2000)_"
  else
    reply = content
  end

  client.create_message message.channel_id, reply, embed
end

client.run
