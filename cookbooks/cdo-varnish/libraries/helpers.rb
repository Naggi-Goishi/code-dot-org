# Various Ruby helper methods to generate Varnish VCL from the base configuration.

# Basic regex matcher for the optional query part of a URL.
QUERY_REGEX = "(\\?.*)?$"

# Takes an array of path-patterns as input, validating and normalizing
# them for use within a Varnish regular expression.
# Returns an array of extension patterns and an array of path-prefixed patterns.
def normalize_paths(paths)
  paths.partition do |path|
    # Strip leading slash
    path.gsub!(/^\//,'')
    is_extension = path[0] == '*'
    if !valid_path?(path) ||
      (is_extension && path.match('/'))
      raise ArgumentError.new("Invalid path: #{path}")
    end
    # Strip leading/trailing wildcard
    path.gsub!(/(^\*|\*$)/,'')
    # Escape some special characters
    path.gsub!(/[.+$"]/){|s| '\\' + s}
    is_extension
  end
end

# The maximum length of a path pattern is 255 characters.
# The value can contain any of the following characters:
# A-Z, a-z (case sensitive, so the path pattern /*.jpg doesn't apply to the file /LOGO.JPG.)
# 0-9
# _ - . $ / ~ " ' @ : +
#
# The following characters are allowed in CloudFront path patterns, but
# are not allowed in our configuration format to reduce complexity:
# * (exactly one wildcard required, either at the start or end of the path)
# ? (No 1-character wildcards allowed)
# &, passed and returned as &amp;
def valid_path?(path)
  # Maximum length
  return false if path.length > 255
  # Valid characters allowed
  char = /[A-Za-z0-9_\-.$\/~"'@:+]/
  # Exactly one wildcard required at start or end
  return false unless path.match /^(\*#{char}*|#{char}*\*)$/
  true
end

# Varnish uses 'bereq' in the 'response' section, 'req' otherwise.
def req(section)
  section == 'response' ? 'bereq' : 'req'
end

# Returns a regex-matcher string based on an array of filename extensions.
def extensions_to_regex(exts)
  return [] if exts.empty?
  ["(#{exts.join '|'})#{QUERY_REGEX}"]
end

def path_to_regex(path)
  '^/' + path
end

# Returns a regex-conditional string fragment based on the provided behavior.
# In the 'proxy' section, ignore extension-based behaviors (e.g., *.png).
def paths_to_regex(path_config, section='request')
  path_config = [path_config] unless path_config.is_a?(Array)
  extensions, paths = normalize_paths(path_config)
  elements = paths.map{|path| path_to_regex(path)}
  elements = extensions_to_regex(extensions.map{|x|x.sub(/^\*/,'')}) + elements unless section == 'proxy'
  elements.empty? ? 'false' : elements.map{|el| "#{req(section)}.url ~ \"#{el}\""}.join(' || ')
end

# Generates the logic string for the specified behavior.
def process_behavior(behavior, app, section)
  if section == 'proxy'
    process_proxy(behavior['proxy'] || app)
  else
    process_cookies(behavior['cookies'], section)
  end
end

# Returns the cookie-filter string for a given 'cookies' behavior.
def process_cookies(cookies, section)
  if section == 'request'
    cookies = ['NO_CACHE'] if cookies == 'none'
    "cookie.filter_except(\"#{cookies.join(',')}\");"
  else
    cookies == 'none' ?
      'unset beresp.http.set-cookie;' :
      ''
  end
end

# Returns the backend-redirect string for a given proxy.
def process_proxy(proxy)
  "set req.backend_hint = #{proxy}.backend();"
end

# Returns the hostname-specific conditional expression for the app provided.
def if_app(app, section)
  app == 'dashboard' ? (req(section)+'.http.host ~ "(dashboard|studio).code.org$"') : nil
end

# Generate an "if(){} else if {} else {}" string from an array of items, conditional Proc, and a block.
def if_else(items, conditional)
  _buf = ''
  items.each_with_index do |item, i|
    condition = conditional.call(item)
    next if condition.to_s == 'false'
    _buf[-1] = ' ' if i != 0
    _buf << "#{i != 0 ? 'else ' : ''}#{condition && "if (#{condition}) "}{\n"
    _buf << yield(item).lines.map{|line| '  ' + line }.join << "\n}\n"
  end
  _buf
end

# Generates the VCL string for each section: 'request', 'response', or 'proxy'.
def setup_behavior(section)
  app_condition = lambda do |app|
    if_app(app, section)
  end
  if_else(%w(dashboard pegasus), app_condition) do |app|
    config = node['cdo-varnish']['config'][app]
    configs = config['behaviors'] + [config['default']]
    path_condition = lambda do |behavior|
      behavior['path'] ? paths_to_regex(behavior['path'], section) : nil
    end
    if_else(configs, path_condition) do |behavior|
      process_behavior(behavior, app, section)
    end
  end
end
