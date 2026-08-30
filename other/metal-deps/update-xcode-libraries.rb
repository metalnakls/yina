#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "pathname"

ROOT = Pathname.new(__dir__).join("../..").realpath
PROJECT = ROOT.join("iina.xcodeproj/project.pbxproj")
LIB_DIR = ROOT.join("deps/lib")

def stable_id(kind, name)
  Digest::SHA256.hexdigest("iina-metal-deps:#{kind}:#{name}")[0, 24].upcase
end

def insert_list(text, object_id, field, entries)
  pattern = /(\t\t#{object_id} \/\*.*?\*\/ = \{.*?\n\t\t\t#{field} = \(\n)/m
  raise "Could not find #{field} list for #{object_id}" unless text.match?(pattern)

  text.sub(pattern) { "#{Regexp.last_match(1)}#{entries}" }
end

libraries = LIB_DIR.glob("*.dylib").map(&:basename).map(&:to_s).sort
raise "No dylibs found in #{LIB_DIR}" if libraries.empty?

text = PROJECT.read

# Remove existing dylib declarations and list memberships. Framework references
# such as Sparkle and system frameworks are deliberately untouched.
text.gsub!(/^\s+[A-F0-9]{24} \/\* lib.*?\.dylib(?: in (?:Frameworks|Copy Dylibs))? \*\/.*[;,]\n/, "")

build_objects = libraries.flat_map do |name|
  file_id = stable_id("file", name)
  framework_id = stable_id("framework", name)
  copy_id = stable_id("copy", name)
  [
    "\t\t#{framework_id} /* #{name} in Frameworks */ = {isa = PBXBuildFile; fileRef = #{file_id} /* #{name} */; };",
    "\t\t#{copy_id} /* #{name} in Copy Dylibs */ = {isa = PBXBuildFile; fileRef = #{file_id} /* #{name} */; settings = {ATTRIBUTES = (CodeSignOnCopy, ); }; };"
  ]
end.join("\n")

file_objects = libraries.map do |name|
  file_id = stable_id("file", name)
  "\t\t#{file_id} /* #{name} */ = {isa = PBXFileReference; lastKnownFileType = \"compiled.mach-o.dylib\"; name = \"#{name}\"; path = \"deps/lib/#{name}\"; sourceTree = \"<group>\"; };"
end.join("\n")

text.sub!("/* Begin PBXBuildFile section */", "/* Begin PBXBuildFile section */\n#{build_objects}")
text.sub!("/* Begin PBXFileReference section */", "/* Begin PBXFileReference section */\n#{file_objects}")

copy_entries = libraries.map do |name|
  "\t\t\t\t#{stable_id('copy', name)} /* #{name} in Copy Dylibs */,\n"
end.join
framework_entries = libraries.map do |name|
  "\t\t\t\t#{stable_id('framework', name)} /* #{name} in Frameworks */,\n"
end.join
group_entries = libraries.map do |name|
  "\t\t\t\t#{stable_id('file', name)} /* #{name} */,\n"
end.join

text = insert_list(text, "84817C991DBDF57C00CC2279", "files", copy_entries)
text = insert_list(text, "84EB1ED31D2F51D3004FA5A1", "files", framework_entries)
text = insert_list(text, "848290731D95978100C3C76C", "children", group_entries)

PROJECT.write(text)
puts "Updated Xcode references for #{libraries.length} arm64 dylibs"
