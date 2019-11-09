require 'minil'
require 'fileutils'
require_relative '../../resources/compose_context'
require 'dragontk/thread_pool'

module AtlasBuilder
  def self.fit_pow2(value)
    current = 0
    i = 1
    while current < value do
      current = 2 ** i
      i += 1
    end
    return current
  end

  def self.texture_map
    @texture_map ||= begin
      result = {}

      Dir.glob(File.join(ENV.fetch('YATM_MINETEST_GAME_MODS_PATH'), "**/textures/*.png")).each do |filename|
        result[File.basename(filename)] = filename
      end

      Dir.glob(File.join(ENV.fetch('YATM_MODPACK_PATH'), "**/textures/*.png")).each do |filename|
        result[File.basename(filename)] = filename
      end

      result
    end
  end

  def self.get_tile_name(tile_name)
    case tile_name
    when String
      tile_name
    when Hash
      tile_name["name"]
    else
      raise "unexpected tile_name #{tile_name}"
    end.split("^")[0]
  end

  def self.build_node_atlas(mod_name, node_name, node_data, target_dir, root_tmp_dir)
    tmp_dir = File.join(root_tmp_dir, mod_name, node_name)
    if node_data["tiles"] then
    else
      return
    end
    tiles = node_data["tiles"].to_a.map { |(key, value)| [key.to_i, value] }.sort
    special_tiles = node_data["special_tiles"].to_a.map { |(key, value)| [key.to_i, value] }.sort

    ctx = Compose::Context.new("web/atlas/#{mod_name}/#{node_name}", root_dir: root_tmp_dir)
    #ctx.add_reference(nil, __FILE__)

    index_tile_names =
      tiles.map do |i, tile_name|
        [i, get_tile_name(tile_name)]
      end

    index_special_tile_names =
      special_tiles.map do |i, tile_name|
        [i, get_tile_name(tile_name)]
      end

    index_tile_names.each do |(i, tile_name)|
      ctx.add_reference(nil, texture_map[tile_name])
      ctx.tag("tile.#{i}", tile_name)
    end
    index_special_tile_names.each do |(i, tile_name)|
      ctx.add_reference(nil, texture_map[tile_name])
      ctx.tag("special_tile.#{i}", tile_name)
    end
    if ctx.is_modified?
      if not ctx.all_tags_referenced?
        puts "Tags Mismatch"
      elsif not ctx.all_loaded_references?
        puts "Not all loaded values have active references"
      else
        puts "Modified normally"
      end
    else
      return
    end

    thread_pool = DragonTK::ThreadPool.new thread_limit: 8, abort_on_exception: true

    p2 = fit_pow2((tiles.size + 1) / 2)

    cw = ch = 16
    image_w = p2 * cw
    image_h = p2 * ch
    image_buffers = thread_pool.thread_limit.times.map do
      Minil::Image.create(image_w, image_h)
    end

    preloaded = {}

    begin
      index_tile_names.each do |(_i, tile_name)|
        texture_filename = texture_map[tile_name]
        if texture_filename then
          thread_pool.spawn do
            preloaded[tile_name] ||= begin
              Minil::Image.load_file(texture_filename)
            end
          end
        end
      end
      index_special_tile_names.each do |(_i, tile_name)|
        texture_filename = texture_map[tile_name]
        if texture_filename then
          thread_pool.spawn do
            preloaded[tile_name] ||= begin
              Minil::Image.load_file(texture_filename)
            end
          end
        end
      end
    ensure
      thread_pool.await(120)
    end

    frame_count = preloaded.reduce(1) do |acc, (tile_name, tile_image)|
      rows = tile_image.height / ch
      [rows, acc].max
    end

    frame_filenames = []
    begin
      frame_count.times do |frame_index|
        thread_pool.spawn do |index:, job_id:|
          image = image_buffers[index]
          index_tile_names.each do |(i, tile_name)|
            x = cw * (i % p2)
            y = ch * (i / p2)
            case node_data["paramtype2"]
            when "facedir"
              :ok
            when "flowingliquid"
              :ok
            when "none"
              :ok
            when "glasslikeliquidlevel"
              index_special_tile_names.each do |(_i, special_tile_name)|
                special_tile_image = preloaded[special_tile_name]
                if special_tile_image then
                  rows = (special_tile_image.height / ch)
                  row = (frame_index % rows)
                  image.blit(special_tile_image, x + 1, y + 1, 1, 1 + row * ch, cw - 2, ch - 2)
                else
                  puts "WARN: missing special tile texture: #{special_tile_name}"
                end
              end
            else
              raise "unexpected paramtype2 #{node_data["paramtype2"].inspect}"
            end
            tile_image = preloaded[tile_name]
            if tile_image then
              rows = (tile_image.height / ch)
              row = (frame_index % rows)
              image.blit(tile_image, x, y, 0, row * ch, cw, ch)
            else
              puts "WARN: missing tile texture: #{tile_name}"
            end
          end

          target_filename = File.join(target_dir, mod_name, node_name, "frame%04d.png" % frame_index)
          frame_filenames << target_filename
          FileUtils.mkdir_p File.dirname(target_filename)
          puts "save: #{target_filename}"
          image.save_file(target_filename)
          image.clear()
        end
      end
    ensure
      thread_pool.await(120)
    end

    begin
      frame_size_limit = 512
      [1, 2, 4, 8].each do |scale|
        if image_h > frame_size_limit
          if scale > 1 then
            puts "Frame exceeds #{frame_size_limit} pixels, skipping scale #{scale}"
            next
          end
        end
        apng_atlas = File.join(tmp_dir, "x#{scale}" + ".apng")
        scaled_dirname = File.join(tmp_dir, "x#{scale}")
        FileUtils::Verbose.mkdir_p scaled_dirname
        scaled_frame_files = []
        begin
          frame_filenames.each do |frame_name|
            basename = File.basename(frame_name)
            scaled_frame_name = File.join(scaled_dirname, basename)
            scaled_frame_files.push scaled_frame_name
            thread_pool.spawn do |index:,**_opts|
              puts "Scaling frame #{basename} by #{scale}x"
              system("convert", frame_name, "-scale", "#{scale * 100}%", scaled_frame_name) || raise
            end
          end
        ensure
          thread_pool.await(120)
        end

        scaled_frame_files = scaled_frame_files.sort

        puts ["apngasm", scaled_frame_files]
        system("sync")
        system("apngasm", "-F", "-d", "100", "-o", apng_atlas, *scaled_frame_files) || raise
        system("apng2gif", apng_atlas) || raise
      end
    end

    # save compose context
    ctx.save_file()
  end
end
