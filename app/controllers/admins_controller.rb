class AdminsController < ApplicationController
  before_action :set_admin, only: [:show, :edit, :update, :delete, :destroy]
  before_action :cant_change_admin_with_smaller_id, only: [:update, :destroy]

  # GET /admins
  # GET /admins.json
  def index
    @admins = Admin.all
  end

  # GET /admins/1
  # GET /admins/1.json
  def show
  end

  # GET /admins/new
  def new
    @admin = Admin.new
  end

  # GET /admins/1/edit
  def edit
    @show_qrcode = 0
    if request.method == "POST" and params.has_key?(:password)
      valid_password = @admin.valid_password?(params[:password])
      if valid_password == false
        flash.now[:alert] = t('Wrong_Password')
      else
        if params.has_key?(:google)
          @show_qrcode = 1
        elsif params.has_key?(:mobile)
          ensure_authentication_token @admin # generate authentication token and save
          @show_qrcode = 2
        elsif params.has_key?(:link)
          ensure_authentication_token @admin # generate authentication token and save
          @show_qrcode = 3
        end
      end
    end
  end

  # POST /admins
  # POST /admins.json
  def create
    @admin = Admin.new(admin_params)

    respond_to do |format|
      if @admin.save
        format.html { redirect_to @admin, notice: t('notice.admin.created') }
      else
        format.html { render action: 'new' }
      end
    end
  end

  # PATCH/PUT /admins/1
  # PATCH/PUT /admins/1.json
  def update
    # don't change password if it is empty
    params[:admin].delete :password if params[:admin][:password].empty?

    respond_to do |format|
      if @admin.update(admin_params)
        format.html { redirect_to @admin, notice: t('notice.admin.updated') }
      else
        format.html { render action: 'edit' }
      end
    end
  end

  def delete
  end

  # DELETE /admins/1
  # DELETE /admins/1.json
  def destroy
    # self-destruction
    if @admin.id == current_admin.id
      redirect_to :back, alert: t('alert.admin.commit_suicide') and return
    end

    # there will be no admins
    admin_count = Admin.count
    if admin_count <= 1
      redirect_to :back, alert: t('alert.admin.no_admins') and return
    end

    @admin.destroy
    session[:admin_id] = nil
    respond_to do |format|
      format.html { redirect_to admins_url, notice: t('notice.admin.deleted') }
    end
  end

  private
    # Use callbacks to share common setup or constraints between actions.
    def set_admin
      @admin = Admin.find(params[:id])

      # remeber last entered job
      session[:admin_id] = params[:id]
    end

    def cant_change_admin_with_smaller_id
      if current_admin.id > @admin.id
        redirect_to :back, alert: t('alert.admin.cant_modify_admin') and return
      end
    end

    # Never trust parameters from the scary internet, only allow the white list through.
    def admin_params
      params.require(:admin).permit(:username, :email, :password)
    end
end
