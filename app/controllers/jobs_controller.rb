class JobsController < ApplicationController
  before_action :set_job, only: [:show, :edit, :update, :delete, :run, :token_run, :destroy, :timestats, :destroy_timestats]

  helper_method :get_parameters_of
  def get_parameters_of(script)
    script.scan(/[^%]?%{(.+?)}/).flatten(1).uniq
  end

  # GET /jobs
  # GET /jobs.json
  def index
    @jobs_by_type = Job.all.order("type_id ASC").group_by(&:type)
    @jobs_count = Job.count
  end

  # GET /jobs/1
  # GET /jobs/1.json
  def show
    require 'digest/md5'
    @job_parameters = Constant.where("name = ?", "job_parameters").first || []
    @job_parameters = YAML::load @job_parameters.content unless @job_parameters.blank?
    @script_hash = Digest::MD5.hexdigest(@job.script)
  end

  def timestats
    created_at = @job.time_stats.pluck(:created_at).last(12).map{|x| x.to_i }
    real = @job.time_stats.pluck(:real).last(12)

    created_at.push created_at[0] if created_at.length == 1
    real.push real[0] if real.length == 1

    render json: { created_at: created_at, real: real, mean_time: @job.mean_time }
  end

  # GET /jobs/new
  def new
    @job = Job.new
  end

  # GET /jobs/1/edit
  def edit
  end

  # POST /jobs
  # POST /jobs.json
  def create
    create_job_with job_params
  end

  # PATCH/PUT /jobs/1
  # PATCH/PUT /jobs/1.json
  def update
    if params.has_key?(:save_and_go_back) and params.has_key?(:referrer)
      destination = params[:referrer]
    else
      destination = @job
    end

    respond_to do |format|
      if @job.update(job_params)
        format.html { redirect_to destination, notice: t('notice.job.updated') }
      else
        format.html { render action: 'edit' }
      end
    end
  end

  def delete
  end

  def destroy_timestats
    @job.time_stats.clear
    @job.update({ mean_time: nil })
    respond_to do |format|
      format.html { redirect_to @job, notice: t('notice.job.timestats_deleted') }
    end
  end

  # DELETE /jobs/1
  # DELETE /jobs/1.json
  def destroy
    @job.time_stats.clear
    @job.destroy
    session[:job_id] = nil
    respond_to do |format|
      format.html { redirect_to jobs_url, notice: t('notice.job.deleted') }
    end
  end

  # GET /jobs/1/run
  include ActionController::Live
  def run
    __run
  end

  skip_before_action :authenticate, only: [:token_run]
  before_action :authenticate_with_token, only: [:token_run]
  def token_run
    __run
  end

  private
  def __run
    require 'streamer/sse'
    require 'net/ssh'
    require 'net/scp'
    require 'benchmark'
    require 'digest/md5'

    response.headers['Content-Type'] = 'text/event-stream'
    sse = Streamer::SSE.new(response.stream)
    begin
      raise t("sse.please_select_server") if @job.server.nil?
      raise t("sse.please_reload_page") unless
        params.has_key?(:hash) and Digest::MD5.hexdigest(@job.script) == params[:hash]

      key_data = @job.server.constant.try(:content).presence || nil

      ssh_params = [@job.server.host, @job.server.username,
        password: @job.server.password, key_data: key_data, timeout: 5]

      if @job.interpreter.try(:path)
        time_used = Benchmark.measure {
          Net::SSH.start *ssh_params do |ssh|
            if @job.interpreter.upload_script_first
              script = @job.script
              script.gsub!(/\r\n?/, "\n")
              ssh.scp.upload!(StringIO.new(script), "/tmp/easyjobs_script") do |ch, name, sent, total|
                sse.write(status(t('sse.upload_progress', name: name, percent: "#{(sent.to_f * 100 / total.to_f).to_i}", sent: sent, total: total)))
              end
              cmd = "#{@job.interpreter.path} /tmp/easyjobs_script"
              sse.write(status(t('sse.running_command', command: cmd)))
              ssh.exec!(cmd) do |channel, stream, data|
                sse.write(data)
              end
            else
              ssh.open_channel do |channel|
                channel.exec(@job.interpreter.path) do |ch, success|
                  channel.send_data @job.script
                  channel.eof!
                  channel.on_data do |ch,data|
                    sse.write(data)
                  end
                end
              end
            end
          end
        }
        record_and_output_real_time time_used, @job, sse
      else

        # job without interpreter (default)
        script = @job.script
        script.gsub!(/\r\n?/, "\n")
        script.gsub!(/\\\n\s*/, "")

        # param substitute
        good_param = 0
        parameters = get_parameters_of(script)
        parameters.each do |p|
          good_param = good_param + 1 if params.has_key?(:parameters) and 
            params[:parameters].has_key?(p) and params[:parameters][p].length > 0
        end

        raise t("sse.params_not_provided") if good_param != parameters.count

        script = script % params[:parameters].symbolize_keys if good_param > 0

        exit_if_non_zero = (params.has_key?(:exit_if_non_zero) && params[:exit_if_non_zero] == "1")

        # execute commands
        time_used = Benchmark.measure {
          Net::SSH.start *ssh_params do |ssh|
            script.lines.each do |line|
              line.strip!
              next if line.empty? or line[0] == "#"
              exit_code = 0
              ssh.exec!(line) do |channel, stream, data|
                sse.write(data)
                channel.on_request("exit-status") do |ch,data|
                  exit_code = data.read_long
                end
              end
              raise t("sse.exit_with_status_code", code: exit_code) if exit_if_non_zero and exit_code > 0
            end
          end
        }
        record_and_output_real_time time_used, @job, sse

      end
    rescue Timeout::Error
      sse.write(status(t('sse.timed_out')))
    rescue Net::SSH::AuthenticationFailed
      sse.write(status(t('sse.auth_failed')))
    rescue IOError
      # the client disconnects
    rescue Exception => e
      sse.write(status(e.message))
    ensure
      sse.close
    end
  end

    def status(string)
      "> #{string}\n"
    end

    # Use callbacks to share common setup or constraints between actions.
    def set_job
      @job = Job.find(params[:id])

      # remeber last entered job
      session[:job_id] = params[:id]
    end

    # Never trust parameters from the scary internet, only allow the white list through.
    def job_params
      params.require(:job).permit(:name, :interpreter_id, :script, :server_id, :type_id)
    end

    def record_and_output_real_time(time_used, job, sse)
      TimeStat.create([{ real: time_used.real, job_id: job.id, job_script_size: job.script.length }])
      mean_time = job.time_stats.average(:real)
      job.update({ mean_time: mean_time })
      sse.write(status(t('sse.time_used', time: time_used.real)))
      sse.write(status(t('sse.mean_time', time: mean_time)))
    end
end
