require 'authorize_net'

module ActiveMerchant #:nodoc:
  module Billing #:nodoc:
    # For more information on the Authorize.Net Gateway please visit their {Integration Center}[http://developer.authorize.net/]
    #
    # The login and password are not the username and password you use to 
    # login to the Authorize.Net Merchant Interface. Instead, you will 
    # use the API Login ID as the login and Transaction Key as the 
    # password.
    # 
    # ==== How to Get Your API Login ID and Transaction Key
    #
    # 1. Log into the Merchant Interface
    # 2. Select Settings from the Main Menu
    # 3. Click on API Login ID and Transaction Key in the Security section
    # 4. Type in the answer to the secret question configured on setup
    # 5. Click Submit
    # 
    # ==== Automated Recurring Billing (ARB)
    # 
    # Automated Recurring Billing (ARB) is an optional service for submitting and managing recurring, or subscription-based, transactions.
    # 
    # To use recurring, update_recurring, cancel_recurring and status_recurring ARB must be enabled for your account.
    # 
    # Information about ARB is available on the {Authorize.Net website}[http://www.authorize.net/solutions/merchantsolutions/merchantservices/automatedrecurringbilling/].
    # Information about the ARB API is available at the {Authorize.Net Integration Center}[http://developer.authorize.net/]
    class AuthorizeNetGemGateway < Gateway
      CARD_CODE_ERRORS = %w( N S )
      AVS_ERRORS = %w( A E N R W Z )
      AVS_REASON_CODES = %w(27 45)
      # Creates a new AuthorizeNetGateway
      #
      # The gateway requires that a valid login and password be passed
      # in the +options+ hash.
      #
      # ==== Options
      #
      # * <tt>:login</tt> -- The Authorize.Net API Login ID (REQUIRED)
      # * <tt>:password</tt> -- The Authorize.Net Transaction Key. (REQUIRED)
      # * <tt>:test</tt> -- +true+ or +false+. If true, perform transactions against the test server. 
      #   Otherwise, perform transactions against the production server.
      def initialize(options = {})
        requires!(options, :login, :password)
        @options = options
        super
      end
      
      # Performs an authorization, which reserves the funds on the customer's credit card, but does not
      # charge the card.
      #
      # ==== Parameters
      #
      # * <tt>money</tt> -- The amount to be authorized as an Integer value in cents.
      # * <tt>card</tt> -- The CreditCard details for the transaction.
      # * <tt>options</tt> -- A hash of optional parameters.
      def authorize(money, credit_card, options = {})
        response = transaction.authorize(convert_amount(money), create_credit_card(credit_card), options)
        convert_response(response)
      end

      # Perform a purchase, which is essentially an authorization and capture in a single operation.
      #
      # ==== Parameters
      #
      # * <tt>money</tt> -- The amount to be purchased as an Integer value in cents.
      # * <tt>payment_info</tt> -- The CreditCard or Check details for the transaction.
      # * <tt>options</tt> -- A hash of optional parameters.
      def purchase(money, payment_details, options = {})
        response = transaction.purchase(convert_amount(money), payment_info(payment_details), options)
        convert_response(response)
      end

      # Captures the funds from an authorized transaction.
      #
      # ==== Parameters
      #
      # * <tt>money</tt> -- The amount to be captured as an Integer value in cents.
      # * <tt>authorization</tt> -- The authorization returned from the previous authorize request.
      def capture(money, authorization, options = {})
        response = transaction.prior_auth_capture(authorization, convert_amount(money))
        convert_response(response)
      end

      # Void a previous transaction
      #
      # ==== Parameters
      #
      # * <tt>authorization</tt> - The authorization returned from the previous authorize request.
      def void(authorization, options = {})
        response = transaction.void(authorization)
        convert_response(response)
      end

      # Refund a transaction.
      #
      # This transaction indicates to the gateway that
      # money should flow from the merchant to the customer.
      #
      # ==== Parameters
      #
      # * <tt>money</tt> -- The amount to be credited to the customer as an Integer value in cents.
      # * <tt>identification</tt> -- The ID of the original transaction against which the refund is being issued.
      # * <tt>options</tt> -- A hash of parameters.
      #
      # ==== Options
      #
      # * <tt>:card_number</tt> -- The credit card number the refund is being issued to. (REQUIRED)
      # * <tt>:first_name</tt> -- The first name of the account being refunded.
      # * <tt>:last_name</tt> -- The last name of the account being refunded.
      # * <tt>:zip</tt> -- The postal code of the account being refunded.
      def refund(money, authorization, options = {})
        payment_details = payment_info(options.slice(:check, :credit_card).values.first)
        response = transaction.refund(convert_amount(money), authorization, payment_details)
        convert_response(response)
      end
      
      protected
      
      def transaction
        AuthorizeNet::AIM::Transaction.new(@options[:login], @options[:password], {:gateway => test? ? :test : :production})
      end
      
      def convert_amount(money)
        '%.2f' % (money / 100.0)
      end
      
      def payment_info(instance)
        case instance
        when ActiveMerchant::Billing::CreditCard
          create_credit_card(instance)
        when ActiveMerchant::Billing::Check
          create_check(instance)
        end
      end
      
      # converts an active_merchant CreditCard class to an authorize.net CreditCard class
      def create_credit_card(credit_card)
        date = DateTime.parse("#{credit_card.month}/#{credit_card.year}")
        AuthorizeNet::CreditCard.new(credit_card.number, date.strftime('%m%y'), {
          :card_code => credit_card.verification_value,
          :card_type => credit_card.type
        })
      end
      
      # converts an active_merchant Check class to an authorize.net ECheck class
      def create_check(check)
        AuthorizeNet::ECheck.new(check.routing_number, check.account_number, check.bank_name, "#{check.first_name} #{check.last_name}", {
          :check_number => check.number,
          :account_type =>  check.account_type
        })
      end
      
      # converts an authorize.net response to an active_merchant response
      def convert_response(response)
        Response.new(response.approved?, message_from(response), response.fields,
          :test => test?, 
          :authorization => response.fields[:transaction_id],
          :fraud_review => response.held?,
          :avs_result => { :code => response.fields[:avs_response] },
          :cvv_result => response.fields[:card_code_response]
        )
      end
      
      def message_from(response)
        if response.declined?
          if CARD_CODE_ERRORS.include?(response.fields[:card_code_response])
            return CVVResult.messages[ response.fields[:card_code_response] ] 
          end
          if AVS_REASON_CODES.include?(response.fields[:response_reason_code]) && AVS_ERRORS.include?(response.fields[:avs_response])
            return AVSResult.messages[ response.fields[:avs_response] ] 
          end
        end
        (response.fields[:response_reason_text] ? response.fields[:response_reason_text].chomp('.') : '')
      end
    end
  end
end