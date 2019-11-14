#!/usr/bin/env ruby
require 'toml-rb'
require 'redcarpet'
require 'json'
require 'yaml'
require 'erubis'
require 'fileutils'
require_relative 'atlas_builder'
require 'dragontk/thread_pool'
require 'time'

module ModConf
  def self.load_file(filename)
    body = File.read(filename)

    result = {}
    body.each_line do |line|
      if line.strip.empty?
        next
      else
        key, value = line.strip.split(/\s*=\s*/)
        if key and value
          result[key] = value
        end
      end
    end

    result
  end
end

class TemplateContext
  attr_reader :data

  def initialize(filename, data, assets)
    @filename = filename
    @data = data
    @assets = assets
  end

  def _binding
    send :binding
  end

  def component(name, data, &block)
    ComponentContext.new(name, data, @assets).render(&block)
  end

  def render(&block)
    Erubis::Eruby.load_file(@filename).result(binding, &block)
  end

  # source is the form of <domain>:/path/to/file
  # e.g. @:/css/main.css would load the css file from the src directory
  def import_asset(source)
    @assets[source] = File.join('/assets', source.split(":")[1])
  end
end

class ComponentContext
  @@component_cache = {}

  attr_reader :name
  attr_reader :data

  def initialize(name, data, assets)
    @name = name
    @data = data
    @assets = assets
  end

  def component_path(name)
    File.join(__dir__, 'src/components', name + '.html.erb')
  end

  def _binding
    send :binding
  end

  private def get_component()
    @@component_cache[self.name] ||= begin
      filename = component_path(self.name)
      Erubis::Eruby.load_file(filename)
    end
  end

  def component(name, data, &block)
    ComponentContext.new(name, data, @assets).render(&block)
  end

  def render(&block)
    get_component().result(binding, &block)
  end

  # source is the form of <domain>:/path/to/file
  # e.g. @:/css/main.css would load the css file from the src directory
  def import_asset(source)
    @assets[source] = File.join('/assets', source.split(":")[1])
  end
end

class Application
  def render_component(name, title, options, &block)
    context = ComponentContext.new("Layout", {
      title: title,
      **options
    }, @assets)

    result =
      context.render() do
        ComponentContext.new(name, options, @assets).render(&block)
      end

    result
  end

  def render_component_to_file(filename, name, title, options = {}, &block)
    result = render_component(name, title, options, &block)
    FileUtils.mkdir_p File.dirname(filename)
    puts "write: #{filename}"
    File.write(filename, result)
  end

  def cache_toml_file(filename, json_basename)
    mtime = File.stat(filename).mtime

    json_filename = File.join(@temp_dir, json_basename % mtime)
    if File.exist?(json_filename)
      puts "Loading cached data from JSON"
      JSON.load(File.read(json_filename))
    else
      puts "Loading TOML '#{filename}' and caching as JSON"
      data = TomlRB.load_file(filename)
      FileUtils.mkdir_p(File.dirname(json_filename))
      File.write(json_filename, JSON.dump(data))
      data
    end
  end

  def build_nodes_pages
    nodes_dir = File.join(@dist_dir, 'nodes')

    exported_nodes_filename = ENV.fetch('YATM_EXPORTED_NODES_FILENAME')
    @nodes = cache_toml_file(exported_nodes_filename, 'yatm_exported_nodes-%d.json')

    @nodes_by_basename = {}
    @nodes.each_with_object(@nodes_by_basename) do |(node_name, node_data), acc|
      basename = node_data["basename"]
      (acc[basename] ||= {})[node_name] = node_data
      acc
    end

    @nodes_by_mod = {}
    @nodes.each do |(node_name, node_data)|
      mod_name, name = node_name.split(":")
      (@nodes_by_mod[mod_name] ||= {})[name] ||= node_data
    end

    @mod_nodes_by_basename = {}
    @nodes_by_mod.each do |(mod_name, nodes)|
      nodes.each do |(node_name, node_data)|
        ((@mod_nodes_by_basename[mod_name] ||= {})[node_data["basename"]] ||= {})[node_name] = node_data
      end
    end

    @nodes_basename_state = {}

    FileUtils.mkdir_p nodes_dir
    @nodes_by_basename.each do |(nodes_basename, nodes)|
      #puts "rendering node #{node_name}"
      mod_name, name = nodes_basename.split(":")
      node_dir = File.join(nodes_dir, mod_name, name)

      FileUtils.mkdir_p node_dir

      display_name = name
      nodes.each do |(node_name, node_data)|
        if node_data["base_description"] then
          display_name = node_data["base_description"].split("\n").first
          break
        end

        if node_data["description"] then
          display_name = node_data["description"].split("\n").first
          break
        end
      end

      @nodes_basename_state[nodes_basename] =
        {
          path: "/nodes/#{mod_name}/#{name}",
          mod_name: mod_name,
          node_name: nodes_basename,
          name: name,
          basename: nodes_basename,
          display_name: display_name,
          sub_nodes: nodes.each_with_object({}) do |(node_name, node_data), acc|
            sub_mod_name, subnode_name = node_name.split(":")
            acc[node_name] = {
              basename: nodes_basename,
              node_name: node_name,
              mod_name: sub_mod_name,
              name: subnode_name,
              tiles: node_data["tiles"],
              drawtype: node_data["drawtype"],
              node_box: node_data["node_box"],
              display_name: node_data["description"].split("\n").first || name,
            }
          end
        }

      render_component_to_file(File.join(node_dir, 'index.html'), "nodes/Show",
        "YATM / Nodes / " + nodes_basename,
        **@nodes_basename_state[nodes_basename]
      )
    end

    target_filename = File.join(nodes_dir, 'index.html')
    render_component_to_file(target_filename, "nodes/Index",
      "YATM / Nodes",
      path: '/nodes',
      nodes: @nodes,
      nodes_by_basename: @nodes_by_basename,
      nodes_by_mod: @nodes_by_mod
    )
  end

  def build_craftitems_pages
    craftitems_dir = File.join(@dist_dir, 'craftitems')

    exported_craftitems_filename = ENV.fetch('YATM_EXPORTED_CRAFTITEMS_FILENAME')
    @craftitems = cache_toml_file(exported_craftitems_filename, 'yatm_exported_craftitems-%d.json')

    @craftitems_by_basename = {}
    @craftitems.each_with_object(@craftitems_by_basename) do |(craftitem_name, craftitem_data), acc|
      basename = craftitem_data["basename"]
      (acc[basename] ||= {})[craftitem_name] = craftitem_data
      acc
    end

    @craftitems_by_mod = {}
    @craftitems.each do |(craftitem_name, craftitem_data)|
      mod_name, name = craftitem_name.split(":")
      (@craftitems_by_mod[mod_name] ||= {})[name] ||= craftitem_data
    end

    @mod_craftitems_by_basename = {}
    @craftitems_by_mod.each do |(mod_name, craftitems)|
      craftitems.each do |(craftitem_name, craftitem_data)|
        ((@mod_craftitems_by_basename[mod_name] ||= {})[craftitem_data["basename"]] ||= {})[craftitem_name] = craftitem_data
      end
    end

    @craftitems_basename_state = {}

    FileUtils.mkdir_p craftitems_dir
    @craftitems_by_basename.each do |(craftitems_basename, craftitems)|
      mod_name, name = craftitems_basename.split(":")
      craftitem_dir = File.join(craftitems_dir, mod_name, name)

      FileUtils.mkdir_p craftitem_dir

      display_name = name
      craftitems.each do |(craftitem_name, craftitem_data)|
        if craftitem_data["base_description"] then
          display_name = craftitem_data["base_description"]
          break
        end

        if craftitem_data["description"] then
          display_name = craftitem_data["description"]
          break
        end
      end

      @craftitems_basename_state[craftitems_basename] =
        {
          path: "/craftitems/#{mod_name}/#{name}",
          mod_name: mod_name,
          craftitem_name: craftitems_basename,
          name: name,
          basename: craftitems_basename,
          display_name: display_name,
          sub_craftitems: craftitems.each_with_object({}) do |(craftitem_name, craftitem_data), acc|
            sub_mod_name, subcraftitem_name = craftitem_name.split(":")
            acc[craftitem_name] = {
              basename: craftitems_basename,
              craftitem_name: craftitem_name,
              mod_name: sub_mod_name,
              name: subcraftitem_name,
              inventory_image: craftitem_data["inventory_image"],
              craftitem_box: craftitem_data["craftitem_box"],
              display_name: craftitem_data["description"] || name,
            }
          end
        }

      render_component_to_file(File.join(craftitem_dir, 'index.html'), "craftitems/Show",
        "YATM / Craft Items / " + craftitems_basename,
        **@craftitems_basename_state[craftitems_basename]
      )
    end

    target_filename = File.join(craftitems_dir, 'index.html')
    render_component_to_file(target_filename, "craftitems/Index",
      "YATM / Craft Items",
      path: '/craftitems',
      craftitems: @craftitems,
      craftitems_by_basename: @craftitems_by_basename,
      craftitems_by_mod: @craftitems_by_mod
    )
  end

  def build_tools_pages
    tools_dir = File.join(@dist_dir, 'tools')

    exported_tools_filename = ENV.fetch('YATM_EXPORTED_TOOLS_FILENAME')
    @tools = cache_toml_file(exported_tools_filename, 'yatm_exported_tools-%d.json')

    @tools_by_basename = {}
    @tools.each_with_object(@tools_by_basename) do |(tool_name, tool_data), acc|
      basename = tool_data["basename"]
      (acc[basename] ||= {})[tool_name] = tool_data
      acc
    end

    @tools_by_mod = {}
    @tools.each do |(tool_name, tool_data)|
      mod_name, name = tool_name.split(":")
      (@tools_by_mod[mod_name] ||= {})[name] ||= tool_data
    end

    @mod_tools_by_basename = {}
    @tools_by_mod.each do |(mod_name, tools)|
      tools.each do |(tool_name, tool_data)|
        ((@mod_tools_by_basename[mod_name] ||= {})[tool_data["basename"]] ||= {})[tool_name] = tool_data
      end
    end

    @tools_basename_state = {}

    FileUtils.mkdir_p tools_dir
    @tools_by_basename.each do |(tools_basename, tools)|
      mod_name, name = tools_basename.split(":")
      tool_dir = File.join(tools_dir, mod_name, name)

      FileUtils.mkdir_p tool_dir

      display_name = name
      tools.each do |(tool_name, tool_data)|
        if tool_data["base_description"] then
          display_name = tool_data["base_description"]
          break
        end

        if tool_data["description"] then
          display_name = tool_data["description"]
          break
        end
      end

      @tools_basename_state[tools_basename] =
        {
          path: "/tools/#{mod_name}/#{name}",
          mod_name: mod_name,
          tool_name: tools_basename,
          name: name,
          basename: tools_basename,
          display_name: display_name,
          sub_tools: tools.each_with_object({}) do |(tool_name, tool_data), acc|
            sub_mod_name, subtool_name = tool_name.split(":")
            acc[tool_name] = {
              basename: tools_basename,
              tool_name: tool_name,
              mod_name: sub_mod_name,
              name: subtool_name,
              inventory_image: tool_data["inventory_image"],
              tool_box: tool_data["tool_box"],
              display_name: tool_data["description"] || name,
            }
          end
        }

      render_component_to_file(File.join(tool_dir, 'index.html'), "tools/Show",
        "YATM / Tools / " + tools_basename,
        **@tools_basename_state[tools_basename]
      )
    end

    target_filename = File.join(tools_dir, 'index.html')
    render_component_to_file(target_filename, "tools/Index",
      "YATM / Tools",
      path: '/tools',
      tools: @tools,
      tools_by_basename: @tools_by_basename,
      tools_by_mod: @tools_by_mod
    )
  end

  def build_mod_pages
    @mods = {}
    mod_confs = []
    Dir.glob("/home/icy/docs/codes/IceDragon/minetest-mods/yatm/**/mod.conf").each do |mod_conf_filename|
      mod_conf = ModConf.load_file(mod_conf_filename)

      name = mod_conf['name']
      @mods[name] = mod_conf
    end

    @mods.each do |(mod_name, mod_conf)|
      render_component_to_file(File.join(@dist_dir, "mods/#{mod_name}/index.html"), "mods/Show",
        "YATM / Mod / #{mod_name}",
        path: "/mods/#{mod_name}",
        mods: @mods,
        name: mod_name,
        mod_conf: mod_conf,

        nodes: @nodes_by_mod[mod_name] || {},
        nodes_by_basename: @mod_nodes_by_basename[mod_name] || {},

        craftitems: @craftitems_by_mod[mod_name] || {},
        craftitems_by_basename: @mod_craftitems_by_basename[mod_name] || {},

        tools: @tools_by_mod[mod_name] || {},
        tools_by_basename: @mod_tools_by_basename[mod_name] || {}
      )
    end

    render_component_to_file(File.join(@dist_dir, 'mods/index.html'), "mods/Index",
      "YATM / Mods",
      path: '/mods',
      mod_confs: @mods.values
    )
  end

  def build_home_pages
    render_component_to_file(File.join(@dist_dir, 'index.html'), "about/Index",
      "YATM / About",
      path: '/'
    )
  end

  def build_posts_pages
    @posts = []
    Dir.chdir File.join(__dir__, 'src/posts') do
      Dir.glob("**/index.{md,html.erb}").each do |filename|
        @posts.push({
          basename: filename,
          filename: File.expand_path(filename),
          path: "/posts/#{File.dirname(filename)}"
        })
      end
    end

    @posts.each do |entry|
      filename = entry[:filename]
      basename = entry[:basename]
      path = entry[:path]
      #entry[:date] = Time.now

      entry[:header] = {}

      body =
        case File.extname(filename)
        when ".erb"
          TemplateContext.new(filename, {
            post: entry,
            nodes: @nodes,
            nodes_basename_state: @nodes_basename_state,
            craftitems_basename_state: @craftitems_basename_state,
            tools_basename_state: @tools_basename_state,
          }, @assets).render()
        when ".md"
          contents = File.read(filename)

          new_lines = []
          header = []
          in_header = false
          contents.each_line do |line|
            case line.strip
            when "---"
              in_header = !in_header
            else
              if in_header then
                header << line
              else
                new_lines << line
              end
            end
          end

          entry[:header] = YAML.load(header.join())
          entry[:title] = entry[:header]["title"] || path
          entry[:summary] = entry[:header]["summary"]
          if entry[:header]["date"]
            entry[:date] = Time.parse(entry[:header]["date"])
          end

          contents = new_lines.join()
          Redcarpet::Markdown.new(Redcarpet::Render::HTML.new).render(contents)
        end

      #entry[:summary] ||= begin
      #  if body.size > 255 then
      #    body.slice(0, 255) + "..."
      #  else
      #    body
      #  end
      #end

      render_component_to_file(File.join(@dist_dir, "#{path}/index.html"), "posts/Show",
        "YATM / Post / #{entry[:title]}",
        path: path,
        post: entry,
      ) do
        body
      end
    end

    render_component_to_file(File.join(@dist_dir, 'posts/index.html'), "posts/Index",
      "YATM / Posts",
      path: '/posts',
      posts: @posts.sort_by do |entry|
        entry[:date]
      end.reverse
    )
  end

  def build_design_pages
    render_component_to_file(File.join(@dist_dir, 'design/index.html'), "design/Index",
      "YATM / Design",
      path: '/design'
    )
  end

  def build_tutorials_pages
    render_component_to_file(File.join(@dist_dir, 'tutorials/index.html'), "tutorials/Index",
      "YATM / Tutorials",
      path: '/tutorials'
    )
  end

  def build_download_pages
    render_component_to_file(File.join(@dist_dir, 'downloads/index.html'), "downloads/Index",
      "YATM / Downloads",
      path: '/downloads'
    )
  end

  def build_website_pages
    render_component_to_file(File.join(@dist_dir, 'website/index.html'), "website/Index",
      "YATM / Website",
      path: '/website'
    )
  end

  def build_error_pages
    render_component_to_file(File.join(@dist_dir, '404.html'), "404",
      "YATM / 404",
      path: '/404'
    )
  end

  def handle_assets()
    generated_atlases = {}
    thread_pool = DragonTK::ThreadPool.new thread_limit: 8, abort_on_exception: true
    begin
      @assets.each do |source, local|
        thread_pool.spawn do
          puts "Setting up asset #{source} for #{local}"
          domain, path = source.split(":")
          asset_path = File.join(@temp_dir, "/tmp/assets/", path)

          case domain
          when "@"
            target_filename = File.join(@dist_dir, 'assets', path)
            if not File.exist?(target_filename) or File.mtime(target_filename) != File.mtime(File.join(@src_dir, path))
              FileUtils.mkdir_p File.dirname(target_filename)
              FileUtils::Verbose.cp(File.join(@src_dir, path), target_filename, preserve: true)
            end
          when "atlas"
            case path
            when /^\/images\/(craftitems|tools)\/(\S+)\/(\S+)\/x4.png$/
              type = $1
              mod_name = $2
              node_name = $3
              key = "#{mod_name}:#{node_name}"

              unless generated_atlases[key]
                generated_atlases[key] = true

                craftitem =
                  case type
                  when "craftitems"
                    @craftitems.fetch(key)
                  when "tools"
                    @tools.fetch(key)
                  else
                    raise "unexpected type #{type}"
                  end

                if craftitem["inventory_image"]
                  source_filename = AtlasBuilder.texture_map[craftitem["inventory_image"]]

                  if source_filename && File.exist?(source_filename)
                    unless File.exist?(asset_path)
                      FileUtils.mkdir_p File.dirname(asset_path)
                      #FileUtils::Verbose.cp source_filename, asset_path
                      system("convert", source_filename, "-scale", "400%", asset_path) || raise
                    end
                  else
                    STDERR.puts "WARN: Missing asset #{asset_path}"
                  end
                else
                  STDERR.puts "WARN: No asset for #{type} #{key}"
                end
              end
            when /^\/images\/nodes\/(\S+)\/(\S+)\/(\S+)$/
              mod_name = $1
              node_name = $2
              basename = $3.split("^")[0]
              key = "#{mod_name}:#{node_name}"

              unless generated_atlases[key]
                generated_atlases[key] = true
                node_data = @nodes_by_mod[mod_name][node_name]
                AtlasBuilder.build_node_atlas(
                  mod_name, node_name, node_data,
                  File.join(@temp_dir, "/assets/images/nodes/"),
                  File.join(@temp_dir, "/tmp/assets/images/nodes/")
                )
              end
            end

            system("sync")
            if File.exist?(asset_path)
              target_filename = File.join(@dist_dir, "assets", path)

              should_copy = false

              if File.exist?(target_filename)
                tfmtime = File.mtime(target_filename)
                assetmtime = File.mtime(asset_path)

                should_copy = tfmtime != assetmtime
                if should_copy then
                  STDERR.puts "MTIME-DIFFERS: #{target_filename} mtime (#{tfmtime}) differs from #{asset_path} (#{assetmtime})"
                  FileUtils::Verbose.rm target_filename
                end
              else
                should_copy = true
                STDERR.puts "#{target_filename} does not exist, copying asset"
              end

              if should_copy
                FileUtils.mkdir_p File.dirname(target_filename)
                FileUtils::Verbose.cp asset_path, target_filename, preserve: true
              end
            else
              STDERR.puts "WARN: Missing asset #{asset_path}"
            end
          else
            raise "unexpected domain #{domain}"
          end
        end
      end
    ensure
      thread_pool.await()
    end
  end

  def handle_public
    system("rsync", "-haPc", "--inplace", @public_dir + "/", @dist_dir)
  end

  def run(argv)
    @src_dir = File.join(__dir__, 'src')
    @dist_dir = File.join(__dir__, 'dist')
    @temp_dir = File.join(__dir__, 'tmp')
    @public_dir = File.join(__dir__, 'public')

    #FileUtils.rm_rf @dist_dir
    FileUtils.mkdir_p @dist_dir
    system("sync")

    @assets = {}
    build_nodes_pages()
    build_tools_pages()
    build_craftitems_pages()
    build_home_pages()
    build_posts_pages()
    build_design_pages()
    build_tutorials_pages()
    build_mod_pages()
    build_download_pages()
    build_website_pages()
    build_error_pages()

    handle_assets()

    handle_public()

    puts "Syncing"
    system("sync")
    puts "DONE!"
  end
end

Application.new.run(ARGV.dup)
