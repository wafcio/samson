# frozen_string_literal: true
require_relative '../test_helper'

SingleCov.covered!

describe SecretsController do
  def create_global
    create_secret 'production/global/pod2/foo'
  end

  let(:secret) { create_secret 'production/foo/pod2/some_key' }
  let(:other_project) do
    Project.any_instance.stubs(:valid_repository_url).returns(true)
    Project.create!(name: 'Z', repository_url: 'Z')
  end
  let(:attributes) do
    {
      environment_permalink: 'production',
      project_permalink: 'foo',
      deploy_group_permalink: 'pod2',
      key: 'hi',
      value: 'secret',
      comment: 'hello',
      visible: "0",
      deprecated_at: "0"
    }
  end

  as_a_viewer do
    before { create_secret 'production/foo/group/bar' }

    unauthorized :get, :index
    unauthorized :get, :new
    unauthorized :get, :show, id: 'production/foo/group/bar'
    unauthorized :patch, :update, id: 'production/foo/group/bar'
    unauthorized :delete, :destroy, id: 'production/foo/group/bar'
  end

  as_a_project_deployer do
    unauthorized :post, :create, secret: {
      environment_permalink: 'production',
      project_permalink: 'foo',
      deploy_group_permalink: 'group',
      key: 'bar'
    }

    describe '#index' do
      before { create_global }

      it 'renders template without secret values' do
        get :index
        assert_template :index
        assigns[:secrets].size.must_equal 1
        response.body.wont_include secret.value
      end

      it 'can filter by environment' do
        create_secret 'production/global/pod2/bar'
        get :index, params: {search: {environment_permalink: 'production'}}
        assert_template :index
        assigns[:secrets].map(&:first).sort.must_equal ["production/global/pod2/bar", "production/global/pod2/foo"]
      end

      it 'can filter by project' do
        create_secret 'production/foo-bar/pod2/bar'
        get :index, params: {search: {project_permalink: 'foo-bar'}}
        assert_template :index
        assigns[:secrets].map(&:first).must_equal ['production/foo-bar/pod2/bar']
      end

      it 'can filter by deploy group' do
        create_secret 'production/global/pod2/bar'
        get :index, params: {search: {deploy_group_permalink: 'pod2'}}
        assert_template :index
        assigns[:secrets].map(&:first).sort.must_equal ["production/global/pod2/bar", "production/global/pod2/foo"]
      end

      it 'can filter by key' do
        create_secret 'production/foo-bar/pod2/bar'
        get :index, params: {search: {key: 'bar'}}
        assert_template :index
        assigns[:secrets].map(&:first).must_equal ['production/foo-bar/pod2/bar']
      end

      it 'can filter by value' do
        other = create_secret 'production/global/pod2/baz'
        SecretStorage.write other.id, value: 'other', user_id: 1, visible: true, comment: nil, deprecated_at: nil
        get :index, params: {search: {value: 'other'}}
        assert_template :index
        assigns[:secrets].map(&:first).must_equal [other.id]
      end

      it 'raises when vault server is broken' do
        SecretStorage.expects(:lookup_cache).raises(Samson::Secrets::BackendError.new('this is my error'))
        get :index
        assert flash[:error]
      end
    end

    describe "#new" do
      let(:checked) { "checked=\"checked\"" }

      it "renders since we do not know what project the user is planing to create for" do
        get :new
        assert_template :show
      end

      it "renders pre-filled visible false values from params of last form" do
        get :new, params: {secret: {visible: '0'}}
        assert_response :success
        response.body.wont_include "checked=\"checked\""
      end

      it "renders pre-filled visible true values from params of last form" do
        get :new, params: {secret: {visible: '0'}}
        assert_response :success
        response.body.wont_include checked
      end

      it "renders pre-filled visible false values from params of last form with project set" do
        get :new, params: {secret: {visible: '0', project_permalink: 'foo'}}
        assert_response :success
        response.body.wont_include "checked=\"checked\""
      end
    end

    describe '#show' do
      it 'renders for local secret as project-admin' do
        get :show, params: {id: secret}
        assert_template :show
      end

      it 'hides invisible secrets' do
        get :show, params: {id: secret}
        refute assigns(:secret).fetch(:value)
        response.body.wont_include secret.value
      end

      it 'shows visible secrets' do
        secret.update_column(:visible, true)
        get :show, params: {id: secret}
        assert_template :show
        response.body.must_include secret.value
      end

      it 'renders with unfound users' do
        secret.update_column(:updater_id, 32232323)
        get :show, params: {id: secret}
        assert_template :show
        response.body.must_include "Unknown user id"
      end
    end

    describe '#update' do
      it "is unauthrized" do
        put :update, params: {id: secret, secret: {value: 'xxx'}}
        assert_response :unauthorized
      end
    end

    describe "#destroy" do
      it "is unauthorized" do
        delete :destroy, params: {id: secret.id}
        assert_response :unauthorized
      end
    end
  end

  as_a_deployer do
    describe '#index' do
      it 'renders template' do
        get :index
        assert_template :index
      end
    end
  end

  as_a_project_admin do
    describe '#create' do
      it 'creates a secret' do
        post :create, params: {secret: attributes.merge(visible: 'false')}
        assert flash[:notice]
        assert_redirected_to secrets_path
        secret = SecretStorage::DbBackend::Secret.find('production/foo/pod2/hi')
        secret.updater_id.must_equal user.id
        secret.creator_id.must_equal user.id
        secret.visible.must_equal false
        secret.comment.must_equal 'hello'
        secret.deprecated_at.must_equal nil
      end

      it 'writes nil to deprecated_at to make vault work and not store strange values' do
        attributes[:deprecated_at] = "0"
        SecretStorage.expects(:write).with { |_, data| data.fetch(:deprecated_at).must_equal nil }
        post :create, params: {secret: attributes}
      end

      it 'does not override an existing secret' do
        attributes[:key] = secret.id.split('/').last
        post :create, params: {secret: attributes}
        refute flash[:notice]
        assert flash[:error]
        assert_template :show
        secret.reload.value.must_equal 'MY-SECRET'
      end

      it "redirects to new form when user wants to create another secret" do
        post :create, params: {secret: attributes, commit: SecretsController::ADD_MORE}
        flash[:notice].wont_be_nil
        redirect_params = attributes.except(:value).merge(visible: false, deprecated_at: nil)
        assert_redirected_to "/secrets/new?#{{secret: redirect_params}.to_query}"
      end

      it 'renders and sets the flash when invalid' do
        attributes[:key] = ''
        post :create, params: {secret: attributes}
        assert flash[:error]
        assert_template :show
      end

      it "is not authorized to create global secrets" do
        attributes[:project_permalink] = 'global'
        post :create, params: {secret: attributes}
        assert_response :unauthorized
      end

      it "does not log secret values" do
        Rails.logger.stubs(:info)
        Rails.logger.expects(:info).with { |message| message.include?("\"value\"=>\"[FILTERED]\"") }
        post :create, params: {secret: attributes}
      end
    end

    describe '#update' do
      def attributes
        @attributes ||= super.except(*SecretStorage::ID_PARTS)
      end

      def do_update
        patch :update, params: {id: secret.id, secret: attributes}
      end

      before { secret }

      it 'updates' do
        do_update
        flash[:notice].wont_be_nil
        assert_redirected_to secrets_path
        secret.reload
        secret.updater_id.must_equal user.id
        secret.creator_id.must_equal users(:admin).id
      end

      it 'backfills value when user is only updating comment' do
        attributes[:value] = ""
        do_update
        assert_redirected_to secrets_path
        secret.reload
        secret.value.must_equal "MY-SECRET"
        secret.comment.must_equal 'hello'
      end

      it "does not allow backfills when user tries to make hidden visible" do
        attributes[:value] = ""
        attributes[:visible] = "1"
        do_update
        assert_template :show
        assert flash[:error]
      end

      it "does not allow backfills when secret was visible since value should have been visible" do
        attributes[:value] = ""
        SecretStorage.write(
          secret.id, visible: true, value: "secret", user_id: user.id, comment: "", deprecated_at: nil
        )
        do_update
        assert_template :show
        assert flash[:error]
      end

      it 'fails to update when write fails' do
        SecretStorage.expects(:write).returns(false)
        do_update
        assert_template :show
        assert flash[:error]
      end

      it "is does not allow updating key" do
        attributes[:key] = 'bar'
        do_update
        assert_redirected_to secrets_path
        secret.reload.id.must_equal 'production/foo/pod2/some_key'
      end

      describe 'showing a not owned project' do
        let(:secret) { create_secret "production/#{other_project.permalink}/foo/xxx" }

        it "is not allowed" do
          do_update
          assert_response :unauthorized
        end
      end

      describe 'global' do
        let(:secret) { create_global }

        it "is unauthrized" do
          do_update
          assert_response :unauthorized
        end
      end
    end

    describe "#destroy" do
      it "deletes project secret" do
        delete :destroy, params: {id: secret}
        assert_redirected_to "/secrets"
        SecretStorage::DbBackend::Secret.exists?(secret.id).must_equal(false)
      end

      it "deletes secret that already was deleted so we can cleanup after a partial deletetion failure" do
        delete :destroy, params: {id: "a/foo/c/d"}
        assert_redirected_to "/secrets"
      end

      it "responds ok to xhr" do
        delete :destroy, params: {id: secret}, xhr: true
        assert_response :success
        SecretStorage::DbBackend::Secret.exists?(secret.id).must_equal(false)
      end

      it "is unauthorized for global" do
        delete :destroy, params: {id: create_global}
        assert_response :unauthorized
      end
    end
  end

  as_an_admin do
    let(:secret) { create_global }

    describe '#create' do
      before do
        post :create, params: {secret: attributes}
      end

      it 'redirects and sets the flash' do
        assert_redirected_to secrets_path
        flash[:notice].wont_be_nil
      end
    end

    describe '#show' do
      it "renders" do
        get :show, params: {id: secret.id}
        assert_template :show
      end

      it "renders with unknown project" do
        secret.update_column(:id, 'oops/bar')
        get :show, params: {id: secret.id}
        assert_template :show
      end
    end

    describe '#update' do
      it "updates" do
        put :update, params: {id: secret, secret: attributes.except(*SecretStorage::ID_PARTS)}
        assert_redirected_to secrets_path
      end
    end

    describe '#destroy' do
      it 'deletes global secret' do
        delete :destroy, params: {id: secret.id}
        assert_redirected_to "/secrets"
        SecretStorage::DbBackend::Secret.exists?(secret.id).must_equal(false)
      end

      it "works with unknown project" do
        secret.update_column(:id, 'oops/bar')
        delete :destroy, params: {id: secret.id}
        assert_redirected_to "/secrets"
        SecretStorage::DbBackend::Secret.exists?(secret.id).must_equal(false)
      end
    end
  end
end
