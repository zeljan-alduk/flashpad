#!/usr/bin/env ruby
# frozen_string_literal: true
#
# One-time App Store Connect provisioning for FlashPad, done entirely through
# the App Store Connect API (no interactive Apple ID login / 2FA).
#
# It is idempotent: it reuses any matching Bundle ID, certificates, and profile
# that already exist, and only creates what's missing. Run it on a fresh machine
# (or after a cert expires) to recreate the local signing assets.
#
# Requires these env vars (see RUNBOOK.md):
#   ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH, DEVELOPMENT_TEAM
#
# It will:
#   1. register Bundle ID  tech.aldo.flashpad  (MAC_OS) if absent
#   2. create an Apple Distribution + a Mac Installer Distribution certificate
#      (sharing one freshly generated private key) if absent, and import them
#      into the login keychain
#   3. create + install a MAC_APP_STORE provisioning profile for the bundle id
#
# What it CANNOT do (Apple gates these to a human in the browser):
#   - accept the Developer Program / Free Apps agreements
#   - create the *app record* (App Store Connect API forbids apps CREATE)

require 'openssl'
require 'base64'
require 'json'
require 'net/http'
require 'fileutils'

KEY_ID    = ENV.fetch('ASC_KEY_ID')
ISSUER    = ENV.fetch('ASC_ISSUER_ID')
P8        = File.read(ENV.fetch('ASC_KEY_PATH'))
TEAM      = ENV.fetch('DEVELOPMENT_TEAM')
BUNDLE_ID = 'tech.aldo.flashpad'
APP_NAME  = 'FlashPad'

def b64u(d) = Base64.urlsafe_encode64(d).delete('=')

def jwt
  now = Time.now.to_i
  sig = "#{b64u({ alg: 'ES256', kid: KEY_ID, typ: 'JWT' }.to_json)}." \
        "#{b64u({ iss: ISSUER, iat: now, exp: now + 600, aud: 'appstoreconnect-v1' }.to_json)}"
  der = OpenSSL::PKey::EC.new(P8).sign(OpenSSL::Digest::SHA256.new, sig)
  asn = OpenSSL::ASN1.decode(der)
  r = asn.value[0].value.to_s(2).rjust(32, "\x00")
  s = asn.value[1].value.to_s(2).rjust(32, "\x00")
  "#{sig}.#{b64u(r + s)}"
end

def api(method, path, body = nil)
  uri = URI("https://api.appstoreconnect.apple.com#{path}")
  req = Object.const_get("Net::HTTP::#{method}").new(uri)
  req['Authorization'] = "Bearer #{jwt}"
  req['Content-Type'] = 'application/json'
  req.body = body.to_json if body
  res = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |h| h.request(req) }
  [res.code.to_i, (res.body.empty? ? {} : JSON.parse(res.body))]
end

# 1. Bundle ID -------------------------------------------------------------
code, data = api('Get', "/v1/bundleIds?filter[identifier]=#{BUNDLE_ID}&limit=1")
bundle = data['data']&.first
if bundle
  puts "bundleId: reuse #{bundle['id']} (#{BUNDLE_ID})"
else
  code, data = api('Post', '/v1/bundleIds', { data: { type: 'bundleIds',
    attributes: { identifier: BUNDLE_ID, name: APP_NAME, platform: 'MAC_OS', seedId: TEAM } } })
  abort "bundleId create failed (#{code}): #{data}" unless code == 201
  bundle = data['data']
  puts "bundleId: created #{bundle['id']} (#{BUNDLE_ID})"
end
bundle_uid = bundle['id']

# 2. Certificates ----------------------------------------------------------
# One shared private key for both distribution certs (simpler keychain).
keydir = File.expand_path('~/.appstoreconnect/flashpad')
FileUtils.mkdir_p(keydir)
keyfile = File.join(keydir, 'dist.key')
unless File.exist?(keyfile)
  system("openssl genrsa -out #{keyfile} 2048 2>/dev/null") || abort('openssl genrsa failed')
end
csr = File.join(keydir, 'dist.csr')
system("openssl req -new -key #{keyfile} -out #{csr} " \
       "-subj '/CN=FlashPad Distribution/O=#{ENV['CERT_ORG'] || 'FlashPad'}/C=US' 2>/dev/null") ||
  abort('openssl req failed')
csr_content = File.read(csr)

cert_ids = {}
{ 'DISTRIBUTION' => 'Apple Distribution',
  'MAC_INSTALLER_DISTRIBUTION' => 'Mac Installer Distribution' }.each do |type, label|
  code, data = api('Get', "/v1/certificates?filter[certificateType]=#{type}&limit=200")
  existing = data['data']&.find { |c| c.dig('attributes', 'name')&.include?('Distribution') }
  if existing
    cert = existing
    puts "cert #{label}: reuse #{cert['id']}"
  else
    code, data = api('Post', '/v1/certificates', { data: { type: 'certificates',
      attributes: { certificateType: type, csrContent: csr_content } } })
    abort "cert #{label} failed (#{code}): #{data}" unless code == 201
    cert = data['data']
    puts "cert #{label}: created #{cert['id']}"
  end
  cert_ids[type] = cert['id']
  der = Base64.decode64(cert.dig('attributes', 'certificateContent') ||
        api('Get', "/v1/certificates/#{cert['id']}")[1].dig('data', 'attributes', 'certificateContent'))
  cer = File.join(keydir, "#{type}.cer")
  File.binwrite(cer, der)
  system("security import #{cer} -k ~/Library/Keychains/login.keychain-db 2>/dev/null")
end
system("security import #{keyfile} -k ~/Library/Keychains/login.keychain-db " \
       '-T /usr/bin/codesign -T /usr/bin/productbuild -T /usr/bin/productsign -A 2>/dev/null')
puts 'certs: imported into login keychain'

# 3. Provisioning profile --------------------------------------------------
PROFILE_NAME = 'FlashPad Mac App Store'
code, data = api('Get', "/v1/profiles?filter[name]=#{URI.encode_www_form_component(PROFILE_NAME)}&limit=1")
profile = data['data']&.first
if profile
  # Refetch with content
  code, data = api('Get', "/v1/profiles/#{profile['id']}")
  profile = data['data']
  puts "profile: reuse #{profile['id']}"
else
  code, data = api('Post', '/v1/profiles', { data: {
    type: 'profiles',
    attributes: { name: PROFILE_NAME, profileType: 'MAC_APP_STORE' },
    relationships: {
      bundleId: { data: { type: 'bundleIds', id: bundle_uid } },
      certificates: { data: [{ type: 'certificates', id: cert_ids['DISTRIBUTION'] }] },
    },
  } })
  abort "profile create failed (#{code}): #{data}" unless code == 201
  profile = data['data']
  puts "profile: created #{profile['id']}"
end
uuid = profile.dig('attributes', 'uuid')
content = Base64.decode64(profile.dig('attributes', 'profileContent'))
dest = File.expand_path("~/Library/MobileDevice/Provisioning Profiles/#{uuid}.provisionprofile")
FileUtils.mkdir_p(File.dirname(dest))
File.binwrite(dest, content)
puts "profile: installed #{dest}"

puts
puts 'Done. Local signing assets are ready. Remaining manual steps (browser):'
puts '  1. Accept the Developer Program + Free Apps agreements.'
puts "  2. Create the app record: App Store Connect -> Apps -> + -> New App,"
puts "     platform macOS, bundle ID #{BUNDLE_ID}, name #{APP_NAME}, SKU flashpad."
puts 'Then:  fastlane mac release'
