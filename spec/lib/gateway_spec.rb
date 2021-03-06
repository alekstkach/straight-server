require 'spec_helper'

RSpec.describe StraightServer::Gateway do

  before(:each) do
    @gateway = StraightServer::GatewayOnConfig.find_by_id(1)
    @order_mock = double("order mock")
    allow(@order_mock).to receive(:old_status)
    [:id, :gateway=, :save, :to_h, :id=].each { |m| allow(@order_mock).to receive(m) }
    @order_for_keychain_id_args = { amount: 1, keychain_id: 1, currency: nil, btc_denomination: nil }
  end

  it "checks for signature when creating a new order" do
    @gateway.last_keychain_id = 0
    expect( -> { @gateway.create_order(amount: 1, signature: 'invalid', id: 1) }).to raise_exception(StraightServer::GatewayModule::InvalidSignature)
    expect(@gateway).to receive(:order_for_keychain_id).with(@order_for_keychain_id_args).once.and_return(@order_mock)
    @gateway.create_order(amount: 1, signature: hmac_sha256(1, 'secret'), id: 1)
  end

  it "checks md5 signature only if that setting is set ON for a particular gateway" do
    gateway1 = StraightServer::GatewayOnConfig.find_by_id(1)
    gateway2 = StraightServer::GatewayOnConfig.find_by_id(2)
    expect(gateway2).to receive(:order_for_keychain_id).with(@order_for_keychain_id_args).once.and_return(@order_mock)
    expect( -> { gateway1.create_order(amount: 1, signature: 'invalid') }).to raise_exception
    expect( -> { gateway2.create_order(amount: 1, signature: 'invalid') }).not_to raise_exception()
  end

  it "doesn't allow nil or empty order id if signature checks are enabled" do
    expect( -> { @gateway.create_order(amount: 1, signature: hmac_sha256(nil, 'secret'), id: nil) }).to raise_exception(StraightServer::GatewayModule::InvalidOrderId)
    expect( -> { @gateway.create_order(amount: 1, signature: hmac_sha256('', 'secret'), id: '') }).to raise_exception(StraightServer::GatewayModule::InvalidOrderId)
  end

  it "sets order amount in satoshis calculated from another currency" do
    @gateway = StraightServer::GatewayOnConfig.find_by_id(2)
    allow(@gateway).to receive(:address_for_keychain_id).and_return('address')
    allow(@gateway.exchange_rate_adapters.first).to receive(:rate_for).and_return(450.5412)
    expect(@gateway.create_order(amount: 2252.706, currency: 'USD').amount).to eq(500000000)
  end

  it "doesn't allow to create a new order if the gateway is inactive" do
    @gateway.active = false
    expect( -> { @gateway.create_order }).to raise_exception(StraightServer::GatewayModule::GatewayInactive)
    @gateway.active = true
  end

  context "callback url" do

    before(:each) do
      @gateway = StraightServer::GatewayOnConfig.find_by_id(2) # Gateway 2 doesn't require signatures
      @response_mock = double("http response mock")
      expect(@response_mock).to receive(:body).once.and_return('body')
      @order = create(:order)
      allow(@order).to receive(:status).and_return(1)
      allow(@order).to receive(:tid).and_return('tid1')
    end

    it "sends a request to the callback_url" do
      expect(@response_mock).to receive(:code).twice.and_return("200")
      expect(Net::HTTP).to receive(:get_response).and_return(@response_mock)
      @gateway.order_status_changed(@order)
    end

    it "keeps sending request according to the callback schedule if there's an error" do
      expect(@response_mock).to receive(:code).twice.and_return("404")
      expect(@gateway).to receive(:sleep).exactly(10).times
      expect(Net::HTTP).to receive(:get_response).exactly(11).times.and_return(@response_mock)
      expect(URI).to receive(:parse).with('http://localhost:3001/payment-callback?' + @order.to_http_params).exactly(11).times
      @gateway.order_status_changed(@order)
    end

    it "signs the callback if gateway has a secret" do
      @gateway = StraightServer::GatewayOnConfig.find_by_id(1) # Gateway 1 requires signatures
      expect(@response_mock).to receive(:code).twice.and_return("200")
      expect(URI).to receive(:parse).with('http://localhost:3000/payment-callback?' + @order.to_http_params + "&signature=#{hmac_sha256(hmac_sha256(@order.id, 'secret'), 'secret')}")
      expect(Net::HTTP).to receive(:get_response).and_return(@response_mock)
      @gateway.order_status_changed(@order)
    end

    it "receives random data in :data params and sends it back in a callback request" do
      @order.data = 'some random data'
      expect(@gateway).to receive(:order_for_keychain_id).with(@order_for_keychain_id_args).once.and_return(@order)
      @gateway.create_order(amount: 1, data: 'some random data')
      expect(@response_mock).to receive(:code).twice.and_return("200")
      expect(Net::HTTP).to receive(:get_response).and_return(@response_mock)
      expect(URI).to receive(:parse).with('http://localhost:3001/payment-callback?' + @order.to_http_params + "&data=#{@order.data}")
      @gateway.order_status_changed(@order)
    end

    it "saves callback url response in the order's record in DB" do
      allow(@response_mock).to receive(:code).and_return("200")
      allow(Net::HTTP).to receive(:get_response).and_return(@response_mock)
      @gateway.order_status_changed(@order)
      expect(@order.callback_response).to eq({code: "200", body: "body"}) 
    end

  end

  describe "order counters" do

    it "uses 0 for non-existent order counters and increments them" do
      expect(@gateway.order_counters(reload: true)).to include({ new: 0, unconfirmed: 0, paid: 0, underpaid: 0, overpaid: 0, expired: 0 })
      @gateway.increment_order_counter!(:new)
      expect(@gateway.order_counters(reload: true)[:new]).to eq(1)
    end

    it "raises exception when trying to access counters but the feature is disabled" do
      allow(StraightServer::Config).to receive(:count_orders).and_return(false)
      expect( -> { @gateway.order_counters(reload: true) }).to raise_exception(StraightServer::Gateway::OrderCountersDisabled) 
      expect( -> { @gateway.increment_order_counter!(:new) }).to raise_exception(StraightServer::Gateway::OrderCountersDisabled) 
    end

    it "updates gateway's order counters when an associated order status changes" do
      allow_any_instance_of(StraightServer::Order).to receive(:transaction).and_return({ tid: 'xxx' })
      allow(@gateway).to receive(:send_callback_http_request)
      allow(@gateway).to receive(:send_order_to_websocket_client)

      expect(@gateway.order_counters(reload: true)).to eq({ new: 0, unconfirmed: 0, paid: 0, underpaid: 0, overpaid: 0, expired: 0 })
      order = create(:order, gateway_id: @gateway.id)
      expect(@gateway.order_counters(reload: true)).to eq({ new: 1, unconfirmed: 0, paid: 0, underpaid: 0, overpaid: 0, expired: 0 })
      order.status = 2
      expect(@gateway.order_counters(reload: true)).to eq({ new: 0, unconfirmed: 0, paid: 1, underpaid: 0, overpaid: 0, expired: 0 })

      expect(@gateway.order_counters(reload: true)).to eq({ new: 0, unconfirmed: 0, paid: 1, underpaid: 0, overpaid: 0, expired: 0 })
      order = create(:order, gateway_id: @gateway.id)
      expect(@gateway.order_counters(reload: true)).to eq({ new: 1, unconfirmed: 0, paid: 1, underpaid: 0, overpaid: 0, expired: 0 })
      order.status = 1
      expect(@gateway.order_counters(reload: true)).to eq({ new: 0, unconfirmed: 1, paid: 1, underpaid: 0, overpaid: 0, expired: 0 })
      order.status = 5
      expect(@gateway.order_counters(reload: true)).to eq({ new: 0, unconfirmed: 0, paid: 1, underpaid: 0, overpaid: 0, expired: 1 })
    end

    it "doesn't increment orders on status update unless the option is turned on (but no exception raised)" do
      allow(StraightServer::Config).to receive(:count_orders).and_return(false)
      allow_any_instance_of(StraightServer::Order).to receive(:transaction).and_return({ tid: 'xxx' })
      allow(@gateway).to receive(:send_callback_http_request)
      allow(@gateway).to receive(:send_order_to_websocket_client)
      order = create(:order, gateway_id: @gateway.id)
      expect(StraightServer::Config.redis[:connection].get("#{StraightServer::Config.redis[:prefix]}:gateway_#{@gateway.id}:new_orders_counter")).to be_nil
    end

  end

  describe "config based gateway" do

    it "loads all the gateways from the config file and assigns correct attributes" do
      gateway1 = StraightServer::GatewayOnConfig.find_by_id(1)
      gateway2 = StraightServer::GatewayOnConfig.find_by_id(2)
      expect(gateway1).to be_kind_of(StraightServer::GatewayOnConfig)
      expect(gateway2).to be_kind_of(StraightServer::GatewayOnConfig)

      expect(gateway1.pubkey).to eq('xpub-000') 
      expect(gateway1.confirmations_required).to eq(0) 
      expect(gateway1.order_class).to eq("StraightServer::Order") 
      expect(gateway1.name).to eq("default") 

      expect(gateway2.pubkey).to eq('xpub-001') 
      expect(gateway2.confirmations_required).to eq(0) 
      expect(gateway2.order_class).to eq("StraightServer::Order") 
      expect(gateway2.name).to eq("second_gateway") 
    end

    it "saves and retrieves last_keychain_id from the file in the .straight dir" do
      expect(File.read("#{ENV['HOME']}/.straight/default_last_keychain_id").to_i).to eq(0)
      @gateway.increment_last_keychain_id!
      expect(File.read("#{ENV['HOME']}/.straight/default_last_keychain_id").to_i).to eq(1)

      expect(@gateway).to receive(:order_for_keychain_id).with(@order_for_keychain_id_args.merge({ keychain_id: 2})).once.and_return(@order_mock)
      @gateway.create_order(amount: 1, signature: hmac_sha256(1, 'secret'), id: 1)
      expect(File.read("#{ENV['HOME']}/.straight/default_last_keychain_id").to_i).to eq(2)
    end
    
    it "searches for Gateway using regular ids when find_by_hashed_id method is called" do
      expect(StraightServer::GatewayOnConfig.find_by_hashed_id(1)).not_to be_nil
    end

  end

  describe "db based gateway" do

    before(:each) do
      # clean the database
      DB.run("DELETE FROM gateways")

      @gateway = StraightServer::GatewayOnDB.new(
        confirmations_required: 0,
        pubkey:      'xpub-000',
        order_class: 'StraightServer::Order',
        secret:      'secret',
        name:        'default',
        check_signature: true,
        exchange_rate_adapter_names: ['Bitpay', 'Coinbase', 'Bitstamp']
      )
    end
    
    it "saves and retrieves last_keychain_id from the db" do
      @gateway.save
      expect(DB[:gateways][:name => 'default'][:last_keychain_id]).to eq(0)
      @gateway.increment_last_keychain_id!
      expect(DB[:gateways][:name => 'default'][:last_keychain_id]).to eq(1)

      expect(@gateway).to receive(:order_for_keychain_id).with(@order_for_keychain_id_args.merge({ keychain_id: 2})).once.and_return(@order_mock)
      @gateway.create_order(amount: 1, signature: hmac_sha256(1, 'secret'), id: 1)
      expect(DB[:gateways][:name => 'default'][:last_keychain_id]).to eq(2)
    end

    it "encryptes and decrypts the gateway secret" do
      expect(@gateway.send(:encrypt_secret)).to eq("96c1c24edff5c1c2:6THJEZqg+2qlDhtWE2Tytg==")
      expect(@gateway.send(:decrypt_secret)).to eq("secret")
      expect(@gateway.secret).to eq("secret")
    end

    it "finds orders using #find_by_id method which is essentially an alias for Gateway[]" do
      @gateway.save
      expect(StraightServer::GatewayOnDB.find_by_id(@gateway.id)).to eq(@gateway)
    end

    it "assigns hashed_id to gateway and then finds gateway using that value" do
      @gateway.save
      hashed_id = hmac_sha256(@gateway.id, 'global server secret')
      expect(@gateway.hashed_id).to eq(hashed_id)
      expect(StraightServer::GatewayOnDB.find_by_hashed_id(hashed_id)).to eq(@gateway)
    end

  end

  describe "handling websockets" do

    before(:each) do
      StraightServer::GatewayModule.class_variable_set(:@@websockets, { @gateway.id => {} })
      @ws = double("websocket mock")
      allow(@ws).to receive(:on).with(:close)
      allow(@order_mock).to receive(:id).and_return(1)
      allow(@order_mock).to receive(:status).and_return(0)
    end

    it "adds a new websocket for the order" do
      @gateway.add_websocket_for_order(@ws, @order_mock)
      expect(@gateway.websockets).to eq({1 => @ws})
    end

    it "sends a message to the websocket when status of the order is changed and closes the connection" do
      allow(@gateway).to receive(:send_callback_http_request) # ignoring the callback which sends an callback_url request
      expect(@order_mock).to receive(:to_json).and_return("order json info")
      expect(@ws).to receive(:send).with("order json info")
      expect(@ws).to receive(:close)
      @gateway.add_websocket_for_order(@ws, @order_mock)
      @gateway.order_status_changed(@order_mock)
    end

    it "doesn't allow to listen to orders with statuses other than 0 or 1" do
      allow(@order_mock).to receive(:status).and_return(2)
      expect( -> { @gateway.add_websocket_for_order(@ws, @order_mock) }).to raise_exception(StraightServer::Gateway::WebsocketForCompletedOrder)
    end

    it "doesn't allow to create a second websocket for the same order" do
      allow(@order_mock).to receive(:status).and_return(0)
      @gateway.add_websocket_for_order(@ws, @order_mock)
      expect( -> { @gateway.add_websocket_for_order(@ws, @order_mock) }).to raise_exception(StraightServer::Gateway::WebsocketExists)
    end

  end

  def hmac_sha256(key, secret)
    OpenSSL::HMAC.digest('sha256', secret, key.to_s).unpack("H*").first
  end

end
