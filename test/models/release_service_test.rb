# frozen_string_literal: true
require_relative '../test_helper'

SingleCov.covered!

describe ReleaseService do
  include StubGithubAPI

  let(:project) { projects(:test) }
  let(:service) { ReleaseService.new(project) }

  describe "#release!" do
    let(:author) { users(:deployer) }
    let(:commit) { "abcd" * 10 }
    let(:release_params_used) { [] }

    before do
      GITHUB.stubs(:create_release).capture(release_params_used)
      GitRepository.any_instance.expects(:fuzzy_tag_from_ref).returns(nil)
    end

    it "creates a new release" do
      count = Release.count

      service.release(commit: commit, author: author)

      assert_equal count + 1, Release.count
    end

    it "tags the release" do
      service.release(commit: commit, author: author)
      assert_equal [[project.user_repo_part, 'v124', target_commitish: commit]], release_params_used
    end

    it "deploys the commit to stages if they're configured to" do
      stage = project.stages.create!(name: "production", deploy_on_release: true)
      release = service.release(commit: commit, author: author)

      assert_equal release.version, stage.deploys.first.reference
    end

    context 'with release_deploy_conditions hook' do
      let!(:stage) { project.stages.create!(name: "production", deploy_on_release: true) }

      it 'does not deploy if the release_deploy_condition check is false' do
        deployable_condition_check = lambda { |_, _| false }

        Samson::Hooks.with_callback(:release_deploy_conditions, deployable_condition_check) do |_|
          service.release(commit: commit, author: author)

          stage.deploys.first.must_be_nil
        end
      end

      it 'does deploy if the release_deploy_condition check is true' do
        deployable_condition_check = lambda { |_, _| true }

        Samson::Hooks.with_callback(:release_deploy_conditions, deployable_condition_check) do |_|
          release = service.release(commit: commit, author: author)

          assert_equal release.version, stage.deploys.first.reference
        end
      end
    end
  end

  describe "#can_release?" do
    it "can release when it can create tags" do
      stub_github_api("repos/bar/foo", permissions: {push: true})
      assert service.can_release?
    end

    it "cannot release when it cannot create tags" do
      stub_github_api("repos/bar/foo", permissions: {push: false})
      refute service.can_release?
    end

    it "cannot release when user is unauthorized" do
      stub_github_api("repos/bar/foo", {}, 401)
      refute service.can_release?
    end

    it "cannot release when user does not have github access" do
      stub_github_api("repos/bar/foo", {}, 404)
      refute service.can_release?
    end
  end
end
