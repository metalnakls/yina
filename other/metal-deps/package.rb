#!/usr/bin/env ruby

require "digest"
require "fileutils"
require "open3"

def capture(*command)
  stdout, stderr, status = Open3.capture3(*command)
  abort "#{command.join(' ')} failed:\n#{stderr}" unless status.success?
  stdout
end

def run(*command)
  system(*command) || abort("#{command.join(' ')} failed")
end

def dylib_dependencies(path)
  capture("otool", "-L", path).lines.drop(1).map do |line|
    line[/^\s+(.+?) \(compatibility version/, 1]
  end.compact
end

def dylib_id(path)
  output = capture("otool", "-D", path).lines.map(&:strip).reject(&:empty?)
  output.length > 1 ? output[1] : nil
end

def resolve_dependency(dependency, source, search_roots)
  if dependency.start_with?("@loader_path/")
    candidate = File.expand_path(dependency.delete_prefix("@loader_path/"), File.dirname(source))
    return candidate if File.exist?(candidate)
  elsif dependency.start_with?("@rpath/")
    basename = File.basename(dependency)
    ([File.dirname(source)] + search_roots).each do |root|
      candidate = File.join(root, basename)
      return candidate if File.exist?(candidate)
    end
  elsif dependency.start_with?("/")
    return dependency if File.exist?(dependency)
  end
  nil
end

output_dir = ARGV.shift
roots = ARGV
abort "usage: package.rb <output-lib-dir> <root-dylib>..." if output_dir.nil? || roots.empty?

output_dir = File.expand_path(output_dir)
allowed_output_parent = File.expand_path(File.join(__dir__, "../../build/metal-deps"))
unless output_dir.start_with?(allowed_output_parent + File::SEPARATOR)
  abort "refusing output outside #{allowed_output_parent}: #{output_dir}"
end

FileUtils.rm_rf(output_dir)
FileUtils.mkdir_p(output_dir)

search_roots = roots.map { |path| File.dirname(File.realpath(path)) }
search_roots << "/opt/homebrew/lib"
queue = roots.map { |path| File.realpath(path) }
sources = {}

until queue.empty?
  source = queue.shift
  id = dylib_id(source)
  basename = File.basename(id || source)
  destination = File.join(output_dir, basename)

  if sources.key?(basename)
    unless Digest::SHA256.file(sources[basename]) == Digest::SHA256.file(source)
      abort "dependency basename collision: #{sources[basename]} and #{source}"
    end
    next
  end

  FileUtils.cp(source, destination, preserve: true)
  FileUtils.chmod(0o644, destination)
  sources[basename] = source

  dylib_dependencies(source).each do |dependency|
    next if dependency.start_with?("/usr/lib/", "/System/Library/")
    resolved = resolve_dependency(dependency, source, search_roots)
    abort "cannot resolve #{dependency} required by #{source}" unless resolved
    queue << File.realpath(resolved)
  end
end

sources.each do |basename, source|
  destination = File.join(output_dir, basename)
  run("install_name_tool", "-id", "@rpath/#{basename}", destination)

  dylib_dependencies(source).each do |dependency|
    next if dependency.start_with?("/usr/lib/", "/System/Library/")
    resolved = resolve_dependency(dependency, source, search_roots)
    abort "cannot resolve #{dependency} required by #{source}" unless resolved
    dependency_id = dylib_id(File.realpath(resolved))
    dependency_name = File.basename(dependency_id || resolved)
    run("install_name_tool", "-change", dependency, "@rpath/#{dependency_name}", destination)
  end

  architectures = capture("lipo", "-archs", destination).strip
  abort "non-arm64 dependency #{destination}: #{architectures}" unless architectures == "arm64"

  modern = "#{destination}.macos27"
  run("xcrun", "vtool", "-set-build-version", "macos", "27.0", "27.0",
      "-replace", "-output", modern, destination)
  FileUtils.chmod(0o644, modern)
  FileUtils.mv(modern, destination)
  run("codesign", "--force", "--sign", "-", destination)
end

puts "Packaged #{sources.length} arm64 dependencies in #{output_dir}"
