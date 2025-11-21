class GroupSubscription < ActiveRecord::Base
  extend Enumerize
  extend ReplaceableNestedAttributes
  include SubscriptionDelegates
  include TimeFormatHelper

validates_associated :subscription_documents
  validates :vacation_begin_on, :vacation_end_on, presence: true, if: :academic_vacation?
  validates :amocrm_id, uniqueness: true, allow_nil: true, unless: -> { amocrm_id.blank? }

  after_save if: :status_changed_to_success_and_not_double? do
    update_columns(sale_success_on: Time.current)
    update_columns(double_created: true)
    # Delayed::Job.enqueue(Amocrm::Operations::DuplicateLead.new(amocrm_id, group_id, id), queue: :amocrm) unless course.dod_course?
  end

  after_save if: :status_changed_to_meeting? do
    return if disabled_send?
    CosmetologyMailer.meeting_status_notification(self).deliver!
  end

  after_save if: :education_dates_changed? do
    update_one_time_payment if COURSES_FOR_PROMOTION.include?(course.short_name)
  end

  after_save do
    checking_fields_changes
    if amo_module_id.present? && status_changed_to_success?
      GroupSubscriptions::ModuleGroupsBuilder.new(self).build!
    end
    group.recalculate_counters
    if status_changed_to_success? && krasotka_course?
      CosmetologyMailer.krasotka_notify_about_new_courses(student, self).deliver
    end
  end

  after_save if: :expelled_changed? do
    if expelled?
      group.expel_student!(student)
      if module_subscriptions.present?
        module_subscriptions.find_each { |gs| gs.update_columns(expelled: true) }
      end
      clean_payments_bonuses
    end
  end

  after_destroy do
    group.recalculate_counters
  end

  after_save :change_group, if: :change_group?

  after_update :sync_amo_data, if: :sync_amo_data?

  after_save if: :itec_changed? do
    if itec?
      return if disabled_send?
      NotificationMailer.notify_about_itec(student).deliver!
      SmsNotifications.new.notify_about_itec!(self)
    end
  end

    # Если курс K-dist и этап продажи в рамках текущей транзакции меняется на "Успешно реализовано", отправляем студенту предложение о покупке набора материалов для курса
    after_save if: :course_is_K_dist? do
      if status_changed_to_success?
        k_dist_mailing
      end
    end

  scope :ordered, ->() { order(begin_on: :desc) }
  scope :expired, ->() { where("(group_subscriptions.one_time_payment = 'false' and group_subscriptions.end_on + INTERVAL '6 month' < :date) or (group_subscriptions.one_time_payment = 'true' and group_subscriptions.end_on + INTERVAL '12 month' < :date)", date: Date.current) }
  scope :not_expired, ->() { where.not("(group_subscriptions.one_time_payment = 'false' and group_subscriptions.end_on + INTERVAL '6 month' < :date) or (group_subscriptions.one_time_payment = 'true' and group_subscriptions.end_on + INTERVAL '12 month' < :date)", date: Date.current) }
  scope :not_ended, ->() { where('group_subscriptions.end_on >= ?', Date.current) }
  scope :actual_practices, -> { joins(:practices).where('practices.end_on > ?', Date.current) }
  scope :actual, ->() { where(amocrm_status_id: AmocrmStatus.success.id) }
  scope :not_actual, ->() { where.not(amocrm_status_id: AmocrmStatus.success.id) }
  scope :academic_vacation, ->() { where(academic_vacation: true).where('group_subscriptions.vacation_begin_on <= :date AND :date <= group_subscriptions.vacation_end_on', date: Date.current) }
  scope :not_academic_vacation, ->() { where('group_subscriptions.academic_vacation = :vacation OR (group_subscriptions.vacation_begin_on > :date OR group_subscriptions.vacation_end_on < :date)', vacation: false, date: Date.current) }

  def save_and_generate_documents_for_order!
    save!

    with_lock do
      generate_subscription_documents if subscription_documents.blank?

      (subscription_contract || build_subscription_contract).generate!

      if generate_practice_agreement?
        (practice_agreement || build_practice_agreement).generate!(number: 1)
      else
        practice_agreement.destroy! if practice_agreement
      end

      (questionnaire || build_questionnaire).generate!

      if generate_vacation_order?
        (vacation_order || build_vacation_order).generate!
      else
        vacation_order.destroy! if vacation_order
      end

      group_transfers.each { |group_transfer| group_transfer.change_group_order.generate! if group_transfer.correct? && group_transfer.change_group_order }
    end
  end

  def save_and_generate_subscription_documents!
    transaction do
      save!
      subscription_documents.each(&:save!)
    end
  end

  def generate_subscription_documents
    return if student.blank? || course.blank?
    courses.each do |course|
      course.course_documents.where(education_level: student.education_level).each do |course_document|
        education_document = course_document.education_document
        next unless education_document
        subscription_documents.find_or_initialize_by(education_document: education_document,
                                                     course: course)
      end
    end
  end

  def logger
    @logger ||= Logger.new("#{Rails.root}/log/group_subscriptions.log")
  end

  # Статус сделки будет изменен на "Успешно реализовано" ?
  def deal_status_will_change_to_successfully_implemented?
    (self.amocrm_status_id == SUCCESSFULLY_IMPLEMENTED) && self.amocrm_status_id_changed?
  end

  def missing_student_docs_mailing
    if self.course.student_docs_required
      unless (self.student.missing_docs_list.empty? || self.student.have_mail_missing_docs_about?(1.month))
        NotificationMailer.notify_about_missing_student_docs(self.student).deliver_later if send_wsr_notifications? && send_krasotka_notifications? && send_free_course?
        self.student.create_journal_entry_missing_docs_mailing_about
      end
    end
  end
end
