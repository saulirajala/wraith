require "parallel"
require "shellwords"
require "wraith"
require "wraith/helpers/capture_options"
require "wraith/helpers/logger"
require "wraith/helpers/save_metadata"
require "wraith/helpers/utilities"

class Wraith::SaveImages
  include Logging
  attr_reader :wraith, :history, :meta

  def initialize(config, history = false, yaml_passed = false)
    @wraith = Wraith::Wraith.new(config, { yaml_passed: yaml_passed })
    @history = history
    @meta = SaveMetadata.new(@wraith, history)
  end

  def check_paths
    if !wraith.paths
      path = File.read(wraith.spider_file)
      eval(path)
    else
      wraith.paths
    end
  end

  def save_images
    jobs = define_jobs
    parallel_task(jobs)
  end

  def define_jobs
    jobs = []
    check_paths.each do |label, options|
      settings = CaptureOptions.new(options, wraith)

      if settings.resize
        jobs += define_individual_job(label, settings, wraith.widths)
      else
        wraith.widths.each do |width|
          jobs += define_individual_job(label, settings, width)
        end
      end
    end
    jobs
  end

  def define_individual_job(label, settings, width)
    base_file_name    = meta.file_names(width, label, meta.base_label)
    compare_file_name = meta.file_names(width, label, meta.compare_label)

    jobs = []
    jobs << [label, settings.path, prepare_widths_for_cli(width), settings.base_url,    base_file_name,    settings.selector, wraith.before_capture, settings.before_capture]
    jobs << [label, settings.path, prepare_widths_for_cli(width), settings.compare_url, compare_file_name, settings.selector, wraith.before_capture, settings.before_capture] unless settings.compare_url.nil?

    jobs
  end

  def prepare_widths_for_cli(width)
    # prepare for the command line. [30,40,50] => "30,40,50"
    width = width.join(",") if width.is_a? Array
    width
  end

  def prepare_widths_for_chrome(width)
    # prepare for the chrome. "30x40" => "30,40"
    width = width.sub! 'x', ','
    width = prepare_widths_for_cli(width)
    width
  end

  def run_command(command)
    output = []
    IO.popen(command).each do |line|
      logger.info line
      output << line.chomp!
    end.close
    output
  end

  def parallel_task(jobs)
    Parallel.each(jobs, :in_threads => 8) do |_label, _path, width, url, filename, selector, global_before_capture, path_before_capture|
      begin
        command = construct_command(width, url, filename, selector, global_before_capture, path_before_capture)
        attempt_image_capture(command, filename)
      rescue => e
        logger.error e
        create_invalid_image(filename, width)
      end
    end
  end

  def construct_command(width, url, file_name, selector, global_before_capture, path_before_capture)

    selector = selector.gsub '#', '\#' # make sure id selectors aren't escaped in the CLI
    global_before_capture = convert_to_absolute global_before_capture
    path_before_capture   = convert_to_absolute path_before_capture
    home_path = run_command_safely('pwd')

    if "#{meta.engine}" == "chrome"
      # if width is in format 100X100,200X200 => resize_or_reload: 'resize'
      # In this case, we need to generate chrome command twize
      if width.include? ","

        # resize => double command
        screenshots_width = width.split(',')
        command_to_run = ''
        screenshots_width.each_with_index do |screenshot_width, index|
          if index != 0
            command_to_run += ' && '
          end
          screenshot_width    = prepare_widths_for_chrome(screenshot_width)
          new_file_name = file_name.sub('MULTI', "#{screenshot_width}")
          new_file_name = new_file_name.sub! ',', 'x'
          target_folder = File.dirname(new_file_name)
          basename = File.basename(new_file_name)
          logger.warn target_folder

          command_to_run += 'cd ' + target_folder + ' && '
          # @TODO - this command will work only in Mac OS X
          command_to_run += '/Applications/Google\ Chrome.app/Contents/MacOS/Google\ Chrome --headless --disable-gpu --screenshot --window-size=' + "#{screenshot_width} #{url}"

          command_to_run += " && mv screenshot.png " + basename
          command_to_run += " && cd " + home_path
        end
      else
        # reload => single command
        screenshot_width = prepare_widths_for_chrome(width)
        # @TODO - this command will work only in Mac OS X
        command_to_run = '/Applications/Google\ Chrome.app/Contents/MacOS/Google\ Chrome --headless --disable-gpu --screenshot --window-size=' + "#{screenshot_width} #{url}"
        command_to_run += " && mv screenshot.png " + file_name
      end
    else
      width    = prepare_widths_for_cli(width)
      command_to_run = "#{meta.engine}" + " #{wraith.phantomjs_options} '#{wraith.snap_file}' '#{url}' '#{width}' '#{file_name}' '#{selector}' '#{global_before_capture}' '#{path_before_capture}'"
    end
    #logger.debug command_to_run
    command_to_run
  end

  def attempt_image_capture(capture_page_image, filename)
    max_attempts = 5
    max_attempts.times do |i|
      run_command capture_page_image
      return true if image_was_created filename
      logger.warn "Failed to capture image #{filename} on attempt number #{i + 1} of #{max_attempts}"
    end

    fail "Unable to capture image #{filename} after #{max_attempts} attempt(s)" unless image_was_created filename
  end

  def image_was_created(filename)
     # @TODO - need to check if the image was generated even if in resize mode
    wraith.resize or File.exist? filename
  end

  def create_invalid_image(filename, width)
    logger.warn "Using fallback image instead"
    invalid = File.expand_path("../../assets/invalid.jpg", File.dirname(__FILE__))
    FileUtils.cp invalid, filename

    set_image_width(filename, width)
  end

  def set_image_width(image, width)
    `convert #{image.shellescape} -background none -extent #{width}x0 #{image.shellescape}`
  end
end
