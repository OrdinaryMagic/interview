# frozen_string_literal: true

module CoursesShop
  class OrdersController < BaseController
    include ApplicationHelper
    include CartsHelper
    include GroupsHelper
    include HTTParty

    before_action :authenticate_user!

    layout false, except: [:pay, :pay_tkb]

    def create
      @order = create_order!
      if @order.zero_price?
        render json: { location: courses_shop_profile_courses_path }
        return
      end

      if @order.parts == 'true' && @order.group_subscriptions.count == 1
        service = SberBank::OrderGenerator.new(@order)
        service.generate
        location = service.payment_url || root_url
      elsif @order.bank?
        service = AlfaBank::OrderGenerator.new(@order)
        service.generate
        location = service.payment_url || root_url
      elsif @order.bank_tkb?
        location = pay_tkb_courses_shop_order_path(@order)
      else
        location = courses_shop_profile_courses_path(download_document_id: @order.payment_receipt.try(:id))
      end

      if @order.cart? && !@order.bank?
        render json: {
            popup: {
                title: popup_title_text(@order),
                text: popup_description_text(@order),
                name: "#popup-basket-after-payment-overview",
                link: location,
                order_id: @order.id,
                order_price: @order.group_subscriptions.to_a.sum(&:price_with_discount),
                user_name: current_user.full_name,
                user_email: current_user.email,
                user_phone: current_user.phone
            },
            dataLayer: init_data_layer,
            fbEvent: ("fbPurchase" if current_shop.barbershop?)
        }
      else
        render json: { location: location, fbEvent: ("fbPurchase" if current_shop.barbershop?) }
      end
    end

    def pay_tkb
      tkb_api = OpenStruct.new(Rails.application.secrets.tkb_api)
      @order = current_user.orders.find(params[:id])
      endpoint = "api/tcbpay/gate/registerorderfromunregisteredcard"

      url = tkb_api.url + endpoint
      options = {
        "OrderID" => @order.id,
        "Amount" => 100,
        "ClientInfo" => {
          "PhoneNumber" => @order.user.phone ? @order.user.phone.to_s : "",
          "FIO" => @order.user.full_name,
          "Email" => @order.user.email ? @order.user.email : "",
        },
        "ReturnUrl" => tkb_result_courses_shop_order_url(@order),
      }
      headers = {
        "Content-Type" => "application/json",
        "TCB-Header-Login" => tkb_api.login,
        "TCB-Header-Sign" => sign_hash(JSON.generate(options), tkb_api.api_key)
      }
      response = HTTParty.post(
        url,
        headers: headers,
        body: options.to_json,
        verify: false
      )
      if response.parsed_response["errorInfo"]["errorCode"] == 0
        redirect_to response.parsed_response["formURL"]
      else
        redirect_to courses_shop_profile_courses_path
      end
    end

    private

    def create_order!
      order = current_user.orders.new(order_params)
      order.transaction do
        order.entered_bonus_value = order.bonus_amount
        Orders::PaymentsCalculator.new(order).recalculate if order.cart?
        order.save!
        order.group_subscriptions.each { |s| s.save! }
        if order.zero_price?
          order.update_column(:status, Order.status.paid)
        else
          order.group_subscriptions.update_all(pending_payment_at: Time.current) if order.bank?
          order.generate_payment_receipt! if order.receipt?
        end
      end
      if order.group_subscriptions.count > 1
        order.generate_documents!
      else
        order.group_subscriptions.first.save_and_generate_documents!
      end
      CoursesShopMailer.payment_message(order).deliver!
      order
    end
  end
end
