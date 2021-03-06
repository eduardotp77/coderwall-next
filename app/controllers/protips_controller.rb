class ProtipsController < ApplicationController
  before_action :store_location
  before_action :require_login, only: [:new, :create, :edit, :update]

  def home
    redirect_to(trending_url) if signed_in?
    @protips = Protip.all_time_popular + Protip.recently_most_viewed(20)
    protips_store_data
  end

  def index
    order_by = (params[:order_by] ||= :score)
    @protips = Protip.
      includes(:user).
      visible_to(current_user).
      order({order_by => :desc}).
      page(params[:page])

    if params[:order_by] == :score
      @protips = @protips.where('likes_count > 2')
    end
    if params[:topic]
      tags = Category::children(params[:topic].downcase)
      tags = params[:topic].downcase if tags.empty?
      @protips = @protips.with_any_tagged(tags)
    end

    protips_store_data
  end

  def protips_store_data
    data = {
      protips: { items: serialize(@protips) },
    }
    if current_user
      hearted_protips = current_user.likes.
        where(likable_id: @protips.map(&:id)).
        pluck(:likable_id).
        map{|id| dom_id(Protip, id) }

      data[:hearts] = {
        items: hearted_protips,
      }
    end
    store_data(data)
  end

  def spam
    @protips = Protip.spam.page params[:page]
    render action: 'index'
  end

  def mark_spam
    @protip = Protip.find_by_public_id!(params[:protip_id])
    @protip.user.bad_user!
    Rails.cache.clear # TODO: This is a little excessive
    flash[:notice] = "Marked as spam"
    redirect_to slug_protips_url(id: @protip.public_id, slug: @protip.slug)
  end

  def show
    return (@protip = Protip.random.first) if params[:id] == 'random'
    @protip = Protip.includes(:comments).visible_to(current_user).find_by_public_id!(params[:id])
    @comments = @protip.comments.visible_to(current_user)

    data = {
      currentProtip: { item: serialize(@protip) },
      comments: { items: serialize(@comments) }
    }
    if current_user
      hearted_protips = current_user.likes.
        where(likable_id: @protip.id).
        pluck(:likable_id).
        map{|id| dom_id(Protip, id) }

      hearted_comments = current_user.likes.where(
        likable_id: @comments.map(&:id)
      ).pluck(:likable_id).map{|id| dom_id(Comment, id) }

      data[:hearts] = {
        items: hearted_protips + hearted_comments,
      }
    end

    store_data(data)

    respond_to do |format|
      format.html do
        seo_url   = slug_protips_url(id: @protip.public_id, slug: @protip.slug)
        return redirect_to(seo_url, status: 301) unless slugs_match?
        update_view_count(@protip)
        fresh_when(etag_key_for_protip)
      end
      format.json { render(json: @protip) }
    end
  end

  def new
    @protip = Protip.new
  end

  def edit
    @protip = Protip.find_by_public_id!(params[:id])
    return head(:forbidden) unless current_user.can_edit?(@protip)
    render action: 'new'
  end

  def update
    @protip = Protip.find_by_public_id!(params[:id])
    return head(:forbidden) unless current_user.can_edit?(@protip)
    @protip.assign_attributes(protip_params)
    add_spam_fields(@protip)

    if !captcha_valid_user?(params["g-recaptcha-response"], remote_ip)
      flash.now[:notice] = "Let us know if you're human below :D"
      render action: 'new'
      return
    end

    if spam?
      @protip.bad_content = true
      current_user.update!(bad_user: true)
    end

    if @protip.save
      redirect_to protip_url(@protip)
    else
      render action: 'new'
    end
  end

  def create
    @protip = Protip.new(protip_params)
    @protip.user = current_user
    add_spam_fields(@protip)

    if !captcha_valid_user?(params["g-recaptcha-response"], remote_ip)
      flash.now[:notice] = "Let us know if you're human below :D"
      render action: 'new'
      return
    end

    if spam?
      @protip.bad_content = true
      current_user.update!(bad_user: true)
    end

    if @protip.save
      redirect_to protip_url(@protip)
    else
      render action: 'new'
    end
  end

  def destroy
    @protip = Protip.find_by_public_id!(params[:id])
    return head(:forbidden) unless current_user.can_edit?(@protip)
    @protip.destroy
    redirect_to profile_protips_url(username: @protip.user.username, anchor: 'protips')
  end

  protected

  def add_spam_fields(article)
    article.assign_attributes(
      user_agent: request.user_agent,
      user_ip: remote_ip,
      referrer: request.referer,
    )
  end

  def slugs_match?
    params[:slug] == @protip.slug
  end

  def protip_params
    params.require(:protip).permit(:editable_tags, :body, :title)
  end

  def update_view_count(protip)
    if !browser.bot? && browser.known?
      recently_viewed = cookies[:viewd_protips].to_s.split(':')
      if !recently_viewed.include?(protip.public_id)
        protip.increment_view_count!
        recently_viewed << protip.public_id
      end
      cookies[:viewd_protips] = {
        value:    recently_viewed.join(':'),
        expires:  10.minutes.from_now
      }
    end
  end

  def etag_key_for_protip
    {
      etag: [@protip, current_user, 'v2'],
      last_modified: @protip.updated_at.utc,
      public: false
    }
  end

  def spam?
    flags = Spaminator.new.protip_flags(@protip)
    if flags.any?
      logger.info "[SPAM BLOCK] \"#{@protip.title}\"  #{flags.inspect}"
      true
    else
      logger.info "[SPAM ALLOW] \"#{@protip.title}\""
      false
    end
  end
end
