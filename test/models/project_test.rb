# frozen_string_literal: true
require_relative '../test_helper'

SingleCov.covered!

describe Project do
  include StubGithubAPI

  let(:project) { projects(:test) }
  let(:author) { users(:deployer) }
  let(:url) { "git://foo.com:hello/world.git" }

  def clone_repository(project)
    Project.any_instance.unstub(:clone_repository)
    project.send(:clone_repository).join
  end

  before do
    Project.any_instance.stubs(:valid_repository_url).returns(true)
    GitRepository.any_instance.stubs(:fuzzy_tag_from_ref).returns(nil)
  end

  describe "#generate_token" do
    it "generates a secure token when created" do
      Project.create!(name: "hello", repository_url: url).token.wont_be_nil
    end
  end

  describe "#validate_can_release" do
    it "does not check with blank release_branch" do
      project.release_branch = ""
      assert_valid project
    end

    it "does not check with unchanged release_branch" do
      project.update_column(:release_branch, 'foobar')
      assert_valid project
    end

    it "does not check with updated release_branch" do
      project.update_column(:release_branch, 'foobar')
      project.release_branch = 'barfoo'
      assert_valid project
    end

    it "is invalid when check fails" do
      stub_github_api("repos/bar/foo", permissions: {push: false})
      project.release_branch = 'foobar'
      refute_valid project
    end

    it "is valid when check passes" do
      stub_github_api("repos/bar/foo", permissions: {push: true})
      project.release_branch = 'foobar'
      assert_valid project
    end
  end

  describe "#repository_directory" do
    it "has separate repository_directories for same project but different url" do
      project = projects(:test)
      other_project = Project.find(project.id)
      other_project.repository_url = 'git://hello'

      project.repository_directory.wont_equal other_project.repository_directory
    end
  end

  describe "#repository_homepage" do
    it "is github when using github" do
      project.repository_url = "git://github.com/foo/bar"
      project.repository_homepage.must_equal "https://github.com/foo/bar"
    end

    it "is gitlab when using gitlab" do
      project.repository_url = "git://gitlab.com/foo/bar"
      project.repository_homepage.must_equal "https://gitlab.com/foo/bar"
    end

    it "is nothing when unknown" do
      project.repository_homepage.must_equal ""
    end
  end

  describe "#webhook_stages_for" do
    it "returns the stages with mappings for the branch" do
      master_stage = project.stages.create!(name: "master_stage")
      production_stage = project.stages.create!(name: "production_stage")

      project.webhooks.create!(branch: "master", stage: master_stage, source: 'any')
      project.webhooks.create!(branch: "production", stage: production_stage, source: 'travis')

      project.webhook_stages_for("master", "ci", "jenkins").must_equal [master_stage]
      project.webhook_stages_for("production", "ci", "travis").must_equal [production_stage]
    end
  end

  describe "#user_repo_part" do
    it "returns the user/repo part of the repository URL" do
      project = Project.new(repository_url: "git@github.com:foo/bar.git")
      project.user_repo_part.must_equal "foo/bar"
    end

    it "handles user, organisation and repository names with hyphens" do
      project = Project.new(repository_url: "git@github.com:inlight-media/lighthouse-ios.git")
      project.user_repo_part.must_equal "inlight-media/lighthouse-ios"
    end

    it "handles repository names with dashes or dots" do
      project = Project.new(repository_url: "git@github.com:angular/angular.js.git")
      project.user_repo_part.must_equal "angular/angular.js"

      project = Project.new(repository_url: "git@github.com:zendesk/demo_apps.git")
      project.user_repo_part.must_equal "zendesk/demo_apps"
    end

    it "handles https urls" do
      project = Project.new(repository_url: "https://github.com/foo/bar.git")
      project.user_repo_part.must_equal "foo/bar"
    end

    it "works if '.git' is not at the end" do
      project = Project.new(repository_url: "https://github.com/foo/bar")
      project.user_repo_part.must_equal "foo/bar"
    end
  end

  describe 'project repository initialization' do
    let(:repository_url) { 'git@github.com:zendesk/demo_apps.git' }

    it 'does not clean the project when the project is created' do
      project = Project.new(name: 'demo_apps', repository_url: repository_url)
      project.expects(:clean_old_repository).never
      project.save!
    end

    it 'invokes the setup repository callback after creation' do
      project = Project.new(name: 'demo_apps', repository_url: repository_url)
      project.expects(:clone_repository).once
      project.save!
    end

    it 'removes the cached repository after the project has been deleted' do
      project = Project.new(name: 'demo_apps', repository_url: repository_url)
      project.expects(:clone_repository).once
      project.expects(:clean_repository).once
      project.save!
      project.soft_delete!
    end

    it 'removes the old repository and sets up the new repository if the repository_url is updated' do
      new_repository_url = 'git@github.com:angular/angular.js.git'
      project = Project.create!(name: 'demo_apps', repository_url: repository_url)
      project.expects(:clone_repository).once
      original_repo_dir = project.repository.repo_cache_dir
      FileUtils.expects(:rm_rf).with(original_repo_dir).once
      project.update!(repository_url: new_repository_url)
      refute_equal(original_repo_dir, project.repository.repo_cache_dir)
    end

    it 'does not reset the repository if the repository_url is not changed' do
      project = Project.new(name: 'demo_apps', repository_url: repository_url)
      project.expects(:clone_repository)
      project.expects(:clean_old_repository).never
      project.save!
      project.update!(name: 'new_name')
    end

    it 'sets the git repository on disk' do
      project = Project.new(id: 9999, name: 'demo_apps', repository_url: repository_url)
      project.repository.expects(:clone!).returns(true)
      project.repository.expects(:capture_stdout).returns("foo") # other commands would fail from stubbed `clone!`
      clone_repository(project)
    end

    it 'fails to clone the repository and reports the error' do
      project = Project.new(id: 9999, name: 'demo_apps', repository_url: repository_url)
      project.repository.expects(:clone!).returns(false)
      expected_message = "Could not clone git repository #{project.repository_url} for project #{project.name}"
      Airbrake.expects(:notify).with(expected_message)
      clone_repository(project)
    end

    it 'logs that it could not clone the repository when there is an unexpected error' do
      error = 'Unexpected error while cloning the repository'
      project = Project.new(id: 9999, name: 'demo_apps', repository_url: repository_url)
      project.repository.expects(:clone!).raises(error)
      expected_message =
        "Could not clone git repository #{project.repository_url} for project #{project.name} - #{error}"
      Rails.logger.expects(:error).with(expected_message)
      Airbrake.expects(:notify).once
      clone_repository(project)
    end

    it 'does not validate with a bad repo url' do
      Project.any_instance.unstub(:valid_repository_url)
      project = Project.new(id: 9999, name: 'demo_apps', repository_url: 'my_bad_url')
      project.valid?.must_equal false
      project.errors.messages.must_equal repository_url: ["is not valid or accessible"]
    end

    it 'converts repo url with trailing slash' do
      project = Project.new(id: 9999, name: 'demo_apps', repository_url: 'https://example.com/foo/bar/')
      project.valid?.must_equal true
      project.repository_url.must_equal 'https://example.com/foo/bar'
    end

    describe "private url switching" do
      let(:project) { Project.new(id: 9999, name: 'demo_apps', repository_url: 'https://my_bad_url/foo.git') }

      before { Project.any_instance.unstub(:valid_repository_url) }

      it 'tries private repo url when public url fails (user picked wrong format)' do
        GitRepository.any_instance.expects(:capture_stdout).
          with { |*args| args.include?("https://my_bad_url/foo.git") }.returns(false)
        GitRepository.any_instance.expects(:capture_stdout).
          with { |*args| args.include?("git@my_bad_url:foo.git") }.returns(true)
        assert_valid project
        project.repository_url.must_equal "git@my_bad_url:foo.git"
      end

      it 'tries and fails with private repo url when public url fails (user picked wrong format)' do
        GitRepository.any_instance.expects(:capture_stdout).times(2).returns(false)
        refute_valid project
        project.repository_url.must_equal "https://my_bad_url/foo.git"
      end
    end

    it 'can initialize with a local repo' do
      project = Project.new(name: 'demo_apps', repository_url: '/foo/bar/.git')
      project.save!
    end
  end

  describe '#last_deploy_by_group' do
    let(:pod1) { deploy_groups(:pod1) }
    let(:pod2) { deploy_groups(:pod2) }
    let(:pod100) { deploy_groups(:pod100) }
    let(:prod_deploy) { deploys(:succeeded_production_test) }
    let(:staging_deploy) { deploys(:succeeded_test) }
    let(:staging_failed_deploy) { deploys(:failed_staging_test) }
    let!(:user) { users(:deployer) }

    it 'contains releases per deploy group' do
      deploys = project.last_deploy_by_group(Time.now)
      deploys[pod1.id].must_equal prod_deploy
      deploys[pod2.id].must_equal prod_deploy
      deploys[pod100.id].must_equal staging_deploy
    end

    it 'ignores failed deploys' do
      deploys = project.last_deploy_by_group(Time.now)
      deploys[pod100.id].must_equal staging_deploy
    end

    it 'includes failed deploys' do
      deploys = project.last_deploy_by_group(Time.now, include_failed_deploys: true)
      deploys[pod100.id].must_equal staging_failed_deploy
    end

    it "does not contain releases after requested time" do
      staging_deploy.update_column(:updated_at, prod_deploy.updated_at - 2.days)
      deploys = project.last_deploy_by_group(prod_deploy.updated_at - 1.day)
      deploys[pod1.id].must_be_nil
      deploys[pod2.id].must_be_nil
      deploys[pod100.id].must_equal staging_deploy
    end

    it 'contains no releases for undeployed projects' do
      project = Project.create!(name: 'blank_new_project', repository_url: url)
      deploys = project.last_deploy_by_group(Time.now)
      deploys[pod1.id].must_be_nil
      deploys[pod2.id].must_be_nil
      deploys[pod100.id].must_be_nil
    end

    it 'contains no non-releases' do
      prod_deploy.update_column(:release, false)
      deploys = project.last_deploy_by_group(Time.now)
      deploys[pod1.id].must_be_nil
    end

    it 'performs minimal number of queries' do
      Project.create!(name: 'blank_new_project', repository_url: url)
      assert_sql_queries 7 do
        Project.ordered_for_user(user).with_deploy_groups.each do |p|
          p.last_deploy_by_group(Time.now)
        end
      end
    end
  end

  describe '#last_deploy_by_stage' do
    it "finds 1 deploy per stage" do
      project.last_deploy_by_stage.must_equal([deploys(:succeeded_test), deploys(:succeeded_production_test)])
    end

    it "ignores deleted stages" do
      deploys(:succeeded_test).stage.soft_delete!
      project.last_deploy_by_stage.must_equal([deploys(:succeeded_production_test)])
    end

    it "returns nil when nothing was found" do
      Stage.update_all(deleted_at: Time.now)
      project.last_deploy_by_stage.must_be_nil
    end
  end

  describe '#ordered_for_user' do
    it 'returns unstarred projects in alphabetical order' do
      Project.create!(name: 'A', repository_url: url)
      Project.create!(name: 'Z', repository_url: url)
      Project.ordered_for_user(author).map(&:name).must_equal ['A', 'Foo', 'Z']
    end

    it 'returns starred projects in alphabetical order' do
      Project.create!(name: 'A', repository_url: url)
      z = Project.create!(name: 'Z', repository_url: url)
      author.stars.create!(project: z)
      Project.ordered_for_user(author).map(&:name).must_equal ['Z', 'A', 'Foo']
    end
  end

  describe '#docker_repo' do
    with_registries ["docker-registry.example.com/bar"]

    it "builds" do
      project.docker_repo(DockerRegistry.first, "Dockerfile").must_equal "docker-registry.example.com/bar/foo"
    end

    it "builds nonstandard" do
      project.docker_repo(DockerRegistry.first, "Dockerfile.baz").must_equal "docker-registry.example.com/bar/foo-baz"
    end

    it "builds folders" do
      project.docker_repo(DockerRegistry.first, "baz/Dockerfile").must_equal "docker-registry.example.com/bar/foo-baz"
    end
  end

  describe '#soft_delete' do
    before { undo_default_stubs }

    it "clears the repository" do
      project.repository.expects(:clean!)
      assert project.soft_delete!
    end

    it "creates an audit" do
      assert project.soft_delete!
      project.audits.last.audited_changes.keys.must_equal ["permalink", "deleted_at"]
    end
  end

  describe "#release_prior_to" do
    let(:release) { releases(:test) }

    it "finds no release before given if there is none" do
      project.release_prior_to(release).must_be_nil
    end

    it "finds release before given by id" do
      release.update_column(:number, "20")
      recent = Release.create!(commit: 'abab' * 10, author: release.author, project: project)
      recent.update_column(:number, "199")
      newest = Release.create!(commit: 'abab' * 10, author: release.author, project: project)
      newest.previous_release.must_equal recent
    end
  end

  describe "#create_release?" do
    before do
      project.update_column(:release_source, "any")
    end

    describe "with no release source configured" do
      it "is true when it is the release branch" do
        assert project.create_release?(project.release_branch, "test_service_type", "test_service")
      end

      it "is false when it is not the release branch" do
        refute project.create_release?("x", "test_service_type", "test_service")
      end
    end

    describe "with a release source configured" do
      Samson::Integration::SOURCES.each do |release_source|
        it "is true when the source does match" do
          project.update_column(:release_source, release_source)
          assert project.create_release?(project.release_branch, "release_type", release_source)
        end

        it "is always true if the source is any" do
          project.update_column(:release_source, "any")
          assert project.create_release?(project.release_branch, "release_type", "none")
        end

        it "is false when the source doesn't match" do
          project.update_column(:release_source, "none")
          refute project.create_release?(project.release_branch, "release_type", release_source)
        end
      end

      it "is true if the source type matches" do
        project.update_column(:release_source, "any_code")
        assert project.create_release?(project.release_branch, "code", "github")
      end
    end
  end

  describe "#build_docker_image_for_branch?" do
    context 'when the docker release branch is set' do
      before do
        project.docker_release_branch = 'master'
        project.release_branch = 'master-of-puppets'
      end

      it 'returns false for the wrong branch' do
        refute project.build_docker_image_for_branch?('master-of-puppets')
      end

      it 'returns true for the right branch' do
        assert project.build_docker_image_for_branch?('master')
      end
    end

    context 'when the docker release branch is not set' do
      before do
        project.docker_release_branch = nil
        project.release_branch = 'master-of-puppets'
      end

      it 'returns false' do
        refute project.build_docker_image_for_branch?(nil)
        refute project.build_docker_image_for_branch?('master-of-puppets')
      end
    end
  end

  describe "#user_project_roles" do
    it "deletes them on deletion and audits as user change" do
      assert_difference 'Audited::Audit.where(auditable_type: "User").count', +2 do
        assert_difference 'UserProjectRole.count', -2 do
          project.soft_delete!
        end
      end
    end
  end

  describe "#url" do
    it "builds a url" do
      project.url.must_equal "http://www.test-url.com/projects/foo"
    end
  end

  describe "#dockerfile_list" do
    it "is Dockerfile by default" do
      project.dockerfile_list.must_equal ["Dockerfile"]
    end

    it "splits user input" do
      project.dockerfiles = "Dockerfile  Muh File"
      project.dockerfile_list.must_equal ["Dockerfile", "Muh", "File"]
    end
  end
end
