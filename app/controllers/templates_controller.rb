# frozen_string_literal: true

class TemplatesController < ApplicationController
  load_and_authorize_resource :template

  before_action :load_base_template, only: %i[new create]

  def show
    submissions = @template.submissions.accessible_by(current_ability)
    submissions = submissions.active if @template.archived_at.blank?
    submissions = Submissions.search(current_user, submissions, params[:q], search_values: true)
    submissions = Submissions::Filter.call(submissions, current_user, params.except(:status))

    @base_submissions = submissions

    submissions = Submissions::Filter.filter_by_status(submissions, params)

    submissions = if params[:completed_at_from].present? || params[:completed_at_to].present?
                    submissions.order(Submitter.arel_table[:completed_at].maximum.desc)
                  else
                    submissions.order(id: :desc)
                  end

    @pagy, @submissions = pagy_auto(submissions.preload(:template_accesses, submitters: :start_form_submission_events))
  rescue ActiveRecord::RecordNotFound
    redirect_to root_path
  end

  def new
    @template.name = "#{@base_template.name} (#{I18n.t('clone')})" if @base_template
  end

  def edit
    ActiveRecord::Associations::Preloader.new(
      records: [@template],
      associations: [schema_documents: [:blob, { preview_images_attachments: :blob }]]
    ).call

    @template_data =
      @template.as_json.merge(
        documents: @template.schema_documents.as_json(
          methods: %i[metadata signed_uuid],
          include: { preview_images: { methods: %i[url metadata filename] } }
        )
      ).to_json

    render :edit, layout: 'plain'
  end

  def create
    if @base_template
      ActiveRecord::Associations::Preloader.new(
        records: [@base_template],
        associations: [schema_documents: :preview_images_attachments]
      ).call

      @template = Templates::Clone.call(@base_template, author: current_user,
                                                        name: params.dig(:template, :name),
                                                        folder_name: params[:folder_name])
    else
      @template.author = current_user
      @template.folder = TemplateFolders.find_or_create_by_name(current_user, params[:folder_name])
    end

    if params[:account_id].present? && authorized_clone_account_id?(params[:account_id])
      @template.account_id = params[:account_id]
      @template.folder = @template.account.default_template_folder if @template.account_id != current_account.id
    else
      @template.account = current_account
    end

    Templates.maybe_assign_access(@template)

    if @template.save
      Templates::CloneAttachments.call(template: @template, original_template: @base_template) if @base_template

      SearchEntries.enqueue_reindex(@template)

      WebhookUrls.enqueue_events(@template, 'template.created')

      maybe_redirect_to_template(@template)
    else
      render turbo_stream: turbo_stream.replace(:modal, template: 'templates/new'), status: :unprocessable_content
    end
  end

  def update
    @template.assign_attributes(template_params)

    is_name_changed = @template.name_changed?

    @template.save!

    SearchEntries.enqueue_reindex(@template) if is_name_changed

    WebhookUrls.enqueue_events(@template, 'template.updated')

    head :ok
  end

  def destroy
    notice =
      if params[:permanently].in?(['true', true])
        @template.destroy!

        I18n.t('template_has_been_removed')
      else
        @template.update!(archived_at: Time.current)

        I18n.t('template_has_been_archived')
      end

    redirect_back(fallback_location: root_path, notice:)
  end

  def download_fillable
    document = @template.schema_documents.first
    raise ActiveRecord::RecordNotFound, 'Source document not found for this template' unless document

    pdf_data = document.blob.download
    pdf = HexaPDF::Document.new(io: StringIO.new(pdf_data))
    form = pdf.acro_form

    @template.fields.each do |field|
      next if field['areas'].blank?

      field['areas'].each do |area|
        page = pdf.pages[area['page']]
        next unless page

        page_height = page.box.height
        x = area['x'] * page.box.width
        y = page_height - (area['y'] * page_height)
        width = area['w'] * page.box.width
        height = area['h'] * page.height

        rect_y1 = y - height
        rect_y2 = y
        rect = [x, rect_y1, x + width, rect_y2]

        field_name = field['name'] || field['uuid']
        field_widget = nil

        case field['type']
        when 'text', 'date', 'number'
          field_widget = form.create_text_field(field_name, rect:)
        when 'checkbox'
          field_widget = form.create_check_box(field_name, rect:)
        when 'radio'
          option_name = area['option_uuid']
          field_widget = form.create_radio_button(field_name, option_name, rect:)
        end

        page.add_annotation(field_widget) if field_widget
      end
    end

    output_io = StringIO.new
    pdf.write(output_io)
    send_data output_io.string, filename: "#{@template.name}-fillable.pdf", type: 'application/pdf'
  end

  private

  def template_params
    params.require(:template).permit(
      :name,
      { schema: [[:attachment_uuid, :google_drive_file_id, :name,
                  { conditions: [%i[field_uuid value action operation]] }]],
        submitters: [%i[name uuid is_requester linked_to_uuid invite_by_uuid optional_invite_by_uuid email order]],
        fields: [[:uuid, :submitter_uuid, :name, :type,
                  :required, :readonly, :default_value,
                  :title, :description, :prefillable,
                  { preferences: {},
                    default_value: [],
                    conditions: [%i[field_uuid value action operation]],
                    options: [%i[value uuid]],
                    validation: %i[message pattern min max step],
                    areas: [%i[x y w h cell_w attachment_uuid option_uuid page]] }]] }
    )
  end

  def authorized_clone_account_id?(account_id)
    true_user.account_id.to_s == account_id.to_s ||
      true_user.account.linked_accounts.accessible_by(current_ability).exists?(id: account_id)
  end

  def maybe_redirect_to_template(template)
    if template.account == current_account
      redirect_to(edit_template_path(@template))
    else
      redirect_back(fallback_location: root_path, notice: I18n.t('template_has_been_cloned'))
    end
  end

  def load_base_template
    return if params[:base_template_id].blank?

    @base_template = Template.accessible_by(current_ability).find_by(id: params[:base_template_id])
  end
end
