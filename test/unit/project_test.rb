#-- encoding: UTF-8
#-- copyright
# OpenProject is a project management system.
# Copyright (C) 2012-2015 the OpenProject Foundation (OPF)
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License version 3.
#
# OpenProject is a fork of ChiliProject, which is a fork of Redmine. The copyright follows:
# Copyright (C) 2006-2013 Jean-Philippe Lang
# Copyright (C) 2010-2013 the ChiliProject Team
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
#
# See doc/COPYRIGHT.rdoc for more details.
#++
require File.expand_path('../../test_helper', __FILE__)

class ProjectTest < ActiveSupport::TestCase
  fixtures :all

  def setup
    super
    FactoryGirl.create(:type_standard)
    @ecookbook = Project.find(1)
    @ecookbook_sub1 = Project.find(3)
    User.current = nil
  end

  should validate_presence_of :name
  should validate_presence_of :identifier

  should validate_uniqueness_of :identifier

  context 'associations' do
    should have_many :members
    should have_many(:users).through(:members)
    should have_many :member_principals
    should have_many(:principals).through(:member_principals)
    should have_many :enabled_modules
    should have_many :work_packages
    should have_many(:work_package_changes).through(:work_packages)
    should have_many :versions
    should have_many :time_entries
    should have_many :queries
    should have_many :news
    should have_many :categories
    should have_many :boards
    should have_many(:changesets).through(:repository)

    should have_one :repository
    should have_one :wiki

    should have_and_belong_to_many :types
    should have_and_belong_to_many :work_package_custom_fields
  end

  def test_truth
    assert_kind_of Project, @ecookbook
    assert_equal 'eCookbook', @ecookbook.name
  end

  def test_default_attributes
    with_settings default_projects_public: '1' do
      assert_equal true, Project.new.is_public
      assert_equal false, Project.new(is_public: false).is_public
    end

    with_settings default_projects_public: '0' do
      assert_equal false, Project.new.is_public
      assert_equal true, Project.new(is_public: true).is_public
    end

    with_settings sequential_project_identifiers: '1' do
      assert !Project.new.identifier.blank?
      assert Project.new(identifier: '').identifier.blank?
    end

    with_settings sequential_project_identifiers: '0' do
      assert Project.new.identifier.blank?
      assert !Project.new(identifier: 'test').blank?
    end

    with_settings default_projects_modules: ['work_package_tracking', 'repository'] do
      assert_equal ['work_package_tracking', 'repository'], Project.new.enabled_module_names
    end

    assert_equal Type.all, Project.new.types
    assert_equal Type.find(1, 3), Project.new(type_ids: [1, 3]).types
  end

  def test_update
    assert_equal 'eCookbook', @ecookbook.name
    @ecookbook.name = 'eCook'
    assert @ecookbook.save, @ecookbook.errors.full_messages.join('; ')
    @ecookbook.reload
    assert_equal 'eCook', @ecookbook.name
  end

  def test_validate_identifier
    to_test = { 'abc' => true,
                'ab12' => true,
                'ab-12' => true,
                'ab_12' => true,
                '12' => false,
                'new' => false }

    to_test.each do |identifier, valid|
      p = Project.new
      p.identifier = identifier
      p.valid?
      assert_equal valid, p.errors['identifier'].empty?
    end
  end

  def test_members_should_be_active_users
    Project.all.each do |project|
      assert_nil project.members.detect { |m| !(m.user.is_a?(User) && m.user.active?) }
    end
  end

  def test_users_should_be_active_users
    Project.all.each do |project|
      assert_nil project.users.detect { |u| !(u.is_a?(User) && u.active?) }
    end
  end

  def test_archive
    user = @ecookbook.members.first.user
    @ecookbook.archive
    @ecookbook.reload

    assert !@ecookbook.active?
    assert @ecookbook.archived?
    assert !user.projects.include?(@ecookbook)
    # Subproject are also archived
    assert !@ecookbook.children.empty?
    assert @ecookbook.descendants.active.empty?
  end

  def test_archive_should_fail_if_versions_are_used_by_non_descendant_projects
    # Assign an issue of a project to a version of a child project
    WorkPackage.find(4).update_attribute :fixed_version_id, 4

    assert_no_difference "Project.count(:all, :conditions => 'status = #{Project::STATUS_ARCHIVED}')" do
      assert_equal false, @ecookbook.archive
    end
    @ecookbook.reload
    assert @ecookbook.active?
  end

  def test_unarchive
    user = @ecookbook.members.first.user
    @ecookbook.archive
    # A subproject of an archived project can not be unarchived
    assert !@ecookbook_sub1.unarchive

    # Unarchive project
    assert @ecookbook.unarchive
    @ecookbook.reload
    assert @ecookbook.active?
    assert !@ecookbook.archived?
    assert user.projects.include?(@ecookbook)
    # Subproject can now be unarchived
    @ecookbook_sub1.reload
    assert @ecookbook_sub1.unarchive
  end

  # fails because @ecookbook.issues[5 und 6].destroy fails
  # because ActiveRecord::StaleObjectError
  def test_destroy
    # 2 active members
    assert_equal 2, @ecookbook.members.size
    # and 1 is locked
    assert_equal 3, Member.find(:all, conditions: ['project_id = ?', @ecookbook.id]).size
    # some boards
    assert @ecookbook.boards.any?

    @ecookbook.destroy
    # make sure that the project non longer exists
    assert_raise(ActiveRecord::RecordNotFound) { Project.find(@ecookbook.id) }
    # make sure related data was removed
    assert_nil Member.first(conditions: { project_id: @ecookbook.id })
    assert_nil Board.first(conditions: { project_id: @ecookbook.id })
    assert_nil WorkPackage.first(conditions: { project_id: @ecookbook.id })
  end

  def test_destroying_root_projects_should_clear_data
    Journal.destroy_all
    WorkPackage.all.each(&:recreate_initial_journal!)

    Project.roots.each(&:destroy)

    assert_equal 0, Project.count, "Projects were not deleted: #{Project.all.inspect}"
    assert_equal 0, Member.count, "Members were not deleted: #{Member.all.inspect}"
    assert_equal 0, MemberRole.count
    assert_equal 0, WorkPackage.count
    assert_equal 0, Journal.count, "Journals were not deleted: #{Journal.all.inspect}"
    assert_equal 0, EnabledModule.count
    assert_equal 0, Category.count
    assert_equal 0, Relation.count
    assert_equal 0, Board.count
    assert_equal 0, Message.count
    assert_equal 0, News.count
    assert_equal 0, Query.count(conditions: 'project_id IS NOT NULL')
    assert_equal 0, Repository.count
    assert_equal 0, Changeset.count
    assert_equal 0, Change.count
    assert_equal 0, Comment.count
    assert_equal 0, TimeEntry.count
    assert_equal 0, Version.count
    assert_equal 0, Watcher.count
    assert_equal 0, Wiki.count
    assert_equal 0, WikiPage.count
    assert_equal 0, WikiContent.count
    assert_equal 0, Project.connection.select_all('SELECT * FROM projects_types').size
    assert_equal 0, Project.connection.select_all('SELECT * FROM custom_fields_projects').size
    assert_equal 0, CustomValue.count(conditions: { customized_type: ['Project', 'Issue', 'TimeEntry', 'Version'] })
  end

  def test_move_an_orphan_project_to_a_root_project
    sub = Project.find(2)
    sub.set_parent! @ecookbook
    assert_equal @ecookbook.id, sub.parent.id
    @ecookbook.reload
    assert_equal 4, @ecookbook.children.size
  end

  def test_move_an_orphan_project_to_a_subproject
    sub = Project.find(2)
    assert sub.set_parent!(@ecookbook_sub1)
  end

  def test_move_a_root_project_to_a_project
    sub = @ecookbook
    assert sub.set_parent!(Project.find(2))
  end

  def test_should_not_move_a_project_to_its_children
    sub = @ecookbook
    assert !(sub.set_parent!(Project.find(3)))
  end

  def test_set_parent_should_add_roots_in_alphabetical_order
    ProjectCustomField.destroy_all
    Project.delete_all
    Project.create!(name: 'Project C', identifier: 'project-c').set_parent!(nil)
    Project.create!(name: 'Project B', identifier: 'project-b').set_parent!(nil)
    Project.create!(name: 'Project D', identifier: 'project-d').set_parent!(nil)
    Project.create!(name: 'Project A', identifier: 'project-a').set_parent!(nil)

    assert_equal 4, Project.count
    assert_equal Project.all.sort_by(&:name), Project.all.sort_by(&:lft)
  end

  def test_set_parent_should_add_children_in_alphabetical_order
    ProjectCustomField.destroy_all
    parent = Project.create!(name: 'Parent', identifier: 'parent')
    Project.create!(name: 'Project C', identifier: 'project-c').set_parent!(parent)
    Project.create!(name: 'Project B', identifier: 'project-b').set_parent!(parent)
    Project.create!(name: 'Project D', identifier: 'project-d').set_parent!(parent)
    Project.create!(name: 'Project A', identifier: 'project-a').set_parent!(parent)

    parent.reload
    assert_equal 4, parent.children.size
    assert_equal parent.children.sort_by(&:name), parent.children
  end

  def test_rebuild_should_sort_children_alphabetically
    ProjectCustomField.destroy_all
    parent = Project.create!(name: 'Parent', identifier: 'parent')
    Project.create!(name: 'Project C', identifier: 'project-c').move_to_child_of(parent)
    Project.create!(name: 'Project B', identifier: 'project-b').move_to_child_of(parent)
    Project.create!(name: 'Project D', identifier: 'project-d').move_to_child_of(parent)
    Project.create!(name: 'Project A', identifier: 'project-a').move_to_child_of(parent)

    Project.update_all('lft = NULL, rgt = NULL')
    Project.rebuild!

    parent.reload
    assert_equal 4, parent.children.size
    assert_equal parent.children.sort_by(&:name), parent.children
  end

  def test_set_parent_should_update_issue_fixed_version_associations_when_a_fixed_version_is_moved_out_of_the_hierarchy
    # Parent issue with a hierarchy project's fixed version
    parent_issue = WorkPackage.find(1)
    parent_issue.update_attribute(:fixed_version_id, 4)
    parent_issue.reload
    assert_equal 4, parent_issue.fixed_version_id

    # Should keep fixed versions for the issues
    issue_with_local_fixed_version = WorkPackage.find(5)
    issue_with_local_fixed_version.update_attribute(:fixed_version_id, 4)
    issue_with_local_fixed_version.reload
    assert_equal 4, issue_with_local_fixed_version.fixed_version_id

    # Local issue with hierarchy fixed_version
    issue_with_hierarchy_fixed_version = WorkPackage.find(13)
    issue_with_hierarchy_fixed_version.update_attribute(:fixed_version_id, 6)
    issue_with_hierarchy_fixed_version.reload
    assert_equal 6, issue_with_hierarchy_fixed_version.fixed_version_id

    # Move project out of the issue's hierarchy
    moved_project = Project.find(3)
    moved_project.set_parent!(Project.find(2))
    parent_issue.reload
    issue_with_local_fixed_version.reload
    issue_with_hierarchy_fixed_version.reload

    assert_equal 4, issue_with_local_fixed_version.fixed_version_id, 'Fixed version was not keep on an issue local to the moved project'
    assert_equal nil, issue_with_hierarchy_fixed_version.fixed_version_id, 'Fixed version is still set after moving the Project out of the hierarchy where the version is defined in'
    assert_equal nil, parent_issue.fixed_version_id, 'Fixed version is still set after moving the Version out of the hierarchy for the issue.'
  end

  def test_parent
    p = Project.find(6).parent
    assert p.is_a?(Project)
    assert_equal 5, p.id
  end

  def test_ancestors
    a = Project.find(6).ancestors
    assert a.first.is_a?(Project)
    assert_equal [1, 5], a.collect(&:id)
  end

  def test_root
    r = Project.find(6).root
    assert r.is_a?(Project)
    assert_equal 1, r.id
  end

  def test_children
    c = Project.find(1).children
    assert c.first.is_a?(Project)
    # ignore ordering, since it depends on database collation configuration
    # and may order lowercase/uppercase chars in a different order
    assert_equal [3, 4, 5], c.collect(&:id).sort!
  end

  def test_descendants
    d = Project.find(1).descendants
    assert d.first.is_a?(Project)
    assert_equal [5, 6, 3, 4], d.collect(&:id)
  end

  def test_allowed_parents_should_be_empty_for_non_member_user
    Role.non_member.add_permission!(:add_project)
    user = User.find(9)
    assert user.memberships.empty?
    User.current = user
    assert Project.new.allowed_parents.compact.empty?
  end

  def test_allowed_parents_with_add_subprojects_permission
    Role.find(1).remove_permission!(:add_project)
    Role.find(1).add_permission!(:add_subprojects)
    User.current = User.find(2)
    # new project
    assert !Project.new.allowed_parents.include?(nil)
    assert Project.new.allowed_parents.include?(Project.find(1))
    # existing root project
    assert Project.find(1).allowed_parents.include?(nil)
    # existing child
    assert Project.find(3).allowed_parents.include?(Project.find(1))
    assert !Project.find(3).allowed_parents.include?(nil)
  end

  def test_allowed_parents_with_add_project_permission
    Role.find(1).add_permission!(:add_project)
    Role.find(1).remove_permission!(:add_subprojects)
    User.current = User.find(2)
    # new project
    assert Project.new.allowed_parents.include?(nil)
    assert !Project.new.allowed_parents.include?(Project.find(1))
    # existing root project
    assert Project.find(1).allowed_parents.include?(nil)
    # existing child
    assert Project.find(3).allowed_parents.include?(Project.find(1))
    assert Project.find(3).allowed_parents.include?(nil)
  end

  def test_allowed_parents_with_add_project_and_subprojects_permission
    Role.find(1).add_permission!(:add_project)
    Role.find(1).add_permission!(:add_subprojects)
    User.current = User.find(2)
    # new project
    assert Project.new.allowed_parents.include?(nil)
    assert Project.new.allowed_parents.include?(Project.find(1))
    # existing root project
    assert Project.find(1).allowed_parents.include?(nil)
    # existing child
    assert Project.find(3).allowed_parents.include?(Project.find(1))
    assert Project.find(3).allowed_parents.include?(nil)
  end

  def test_users_by_role
    users_by_role = Project.find(1).users_by_role
    assert_kind_of Hash, users_by_role
    role = Role.find(1)
    assert_kind_of Array, users_by_role[role]
    assert users_by_role[role].include?(User.find(2))
  end

  def test_rolled_up_types
    parent = Project.find(1)
    parent.types = Type.find([1, 2])
    child = parent.children.find(3)

    assert_equal [1, 2], parent.type_ids
    assert_equal [2, 3], child.types.collect(&:id)

    assert_kind_of Type, parent.rolled_up_types.first

    assert_equal [999, 1, 2, 3], parent.rolled_up_types.collect(&:id)
    assert_equal [2, 3], child.rolled_up_types.collect(&:id)
  end

  def test_rolled_up_types_should_ignore_archived_subprojects
    parent = Project.find(1)
    parent.types = Type.find([1, 2])
    child = parent.children.find(3)
    child.types = Type.find([1, 3])
    parent.children.each(&:archive)

    assert_equal [1, 2], parent.rolled_up_types.collect(&:id)
  end

  context 'description' do
    setup do
      # this block unfortunately isn't run
      # move first two lines of next to specs up here
      # when you know that it will work
    end

    def test_short_description_returns_shortened_description
      @project = Project.generate!
      @project.description = ('Abcd ' * 5 + "\n") * 11
      @project.summary = ''
      assert_equal (('Abcd ' * 5 + "\n") * 10)[0..-2] + '...', @project.short_description
    end

    def test_short_description_returns_summary
      @project = Project.generate!
      @project.description = ('Abcd ' * 5 + "\n") * 11
      @project.summary = 'In short'
      assert_equal 'In short', @project.short_description
    end
  end

  context '#rolled_up_versions' do
    setup do
      @project = Project.generate!
      @parent_version_1 = Version.generate!(project: @project)
      @parent_version_2 = Version.generate!(project: @project)
    end

    should 'include the versions for the current project' do
      assert_same_elements [@parent_version_1, @parent_version_2], @project.rolled_up_versions
    end

    should 'include versions for a subproject' do
      @subproject = Project.generate!
      @subproject.set_parent!(@project)
      @subproject_version = Version.generate!(project: @subproject)

      assert_same_elements [
        @parent_version_1,
        @parent_version_2,
        @subproject_version
      ], @project.rolled_up_versions
    end

    should 'include versions for a sub-subproject' do
      @subproject = Project.generate!
      @subproject.set_parent!(@project)
      @sub_subproject = Project.generate!
      @sub_subproject.set_parent!(@subproject)
      @sub_subproject_version = Version.generate!(project: @sub_subproject)

      @project.reload

      assert_same_elements [
        @parent_version_1,
        @parent_version_2,
        @sub_subproject_version
      ], @project.rolled_up_versions
    end

    should 'only check active projects' do
      @subproject = Project.generate!
      @subproject.set_parent!(@project)
      @subproject_version = Version.generate!(project: @subproject)
      assert @subproject.archive

      @project.reload

      assert !@subproject.active?
      assert_same_elements [@parent_version_1, @parent_version_2], @project.rolled_up_versions
    end
  end

  def test_shared_versions_none_sharing
    p = Project.find(5)
    v = Version.create!(name: 'none_sharing', project: p, sharing: 'none')
    assert p.shared_versions.include?(v)
    assert !p.children.first.shared_versions.include?(v)
    assert !p.root.shared_versions.include?(v)
    assert !p.siblings.first.shared_versions.include?(v)
    assert !p.root.siblings.first.shared_versions.include?(v)
  end

  def test_shared_versions_descendants_sharing
    p = Project.find(5)
    v = Version.create!(name: 'descendants_sharing', project: p, sharing: 'descendants')
    assert p.shared_versions.include?(v)
    assert p.children.first.shared_versions.include?(v)
    assert !p.root.shared_versions.include?(v)
    assert !p.siblings.first.shared_versions.include?(v)
    assert !p.root.siblings.first.shared_versions.include?(v)
  end

  def test_shared_versions_hierarchy_sharing
    p = Project.find(5)
    v = Version.create!(name: 'hierarchy_sharing', project: p, sharing: 'hierarchy')
    assert p.shared_versions.include?(v)
    assert p.children.first.shared_versions.include?(v)
    assert p.root.shared_versions.include?(v)
    assert !p.siblings.first.shared_versions.include?(v)
    assert !p.root.siblings.first.shared_versions.include?(v)
  end

  def test_shared_versions_tree_sharing
    p = Project.find(5)
    v = Version.create!(name: 'tree_sharing', project: p, sharing: 'tree')
    assert p.shared_versions.include?(v)
    assert p.children.first.shared_versions.include?(v)
    assert p.root.shared_versions.include?(v)
    assert p.siblings.first.shared_versions.include?(v)
    assert !p.root.siblings.first.shared_versions.include?(v)
  end

  def test_shared_versions_system_sharing
    p = Project.find(5)
    v = Version.create!(name: 'system_sharing', project: p, sharing: 'system')
    assert p.shared_versions.include?(v)
    assert p.children.first.shared_versions.include?(v)
    assert p.root.shared_versions.include?(v)
    assert p.siblings.first.shared_versions.include?(v)
    assert p.root.siblings.first.shared_versions.include?(v)
  end

  def test_shared_versions
    parent = Project.find(1)
    child = parent.children.find(3)
    private_child = parent.children.find(5)

    assert_equal [1, 2, 3], parent.version_ids.sort
    assert_equal [4], child.version_ids
    assert_equal [6], private_child.version_ids
    assert_equal [7], Version.find_all_by_sharing('system').collect(&:id)

    assert_equal 6, parent.shared_versions.size
    parent.shared_versions.each do |version|
      assert_kind_of Version, version
    end

    assert_equal [1, 2, 3, 4, 6, 7], parent.shared_versions.collect(&:id).sort
  end

  def test_shared_versions_should_ignore_archived_subprojects
    parent = Project.find(1)
    child = parent.children.find(3)
    child.archive
    parent.reload

    assert_equal [1, 2, 3], parent.version_ids.sort
    assert_equal [4], child.version_ids
    assert !parent.shared_versions.collect(&:id).include?(4)
  end

  def test_shared_versions_visible_to_user
    user = User.find(3)
    parent = Project.find(1)
    child = parent.children.find(5)

    assert_equal [1, 2, 3], parent.version_ids.sort
    assert_equal [6], child.version_ids

    versions = parent.shared_versions.visible(user)

    assert_equal 4, versions.size
    versions.each do |version|
      assert_kind_of Version, version
    end

    assert !versions.collect(&:id).include?(6)
  end

  def test_next_identifier
    ProjectCustomField.delete_all
    Project.create!(name: 'last', identifier: 'p2008040')
    assert_equal 'p2008041', Project.next_identifier
  end

  def test_next_identifier_first_project
    Project.delete_all
    assert_nil Project.next_identifier
  end

  def test_enabled_module_names
    with_settings default_projects_modules: ['work_package_tracking', 'repository'] do
      project = Project.new

      project.enabled_module_names = %w(work_package_tracking news)
      assert_equal %w(news work_package_tracking), project.enabled_module_names.sort
    end
  end

  def test_enabled_module_names_should_not_recreate_enabled_modules
    project = Project.find(1)
    # Remove one module
    modules = project.enabled_modules.slice(0..-2)
    assert modules.any?
    assert_difference 'EnabledModule.count', -1 do
      project.enabled_module_names = modules.collect(&:name)
    end
    project.reload
    # Ids should be preserved
    assert_equal project.enabled_module_ids.sort, modules.collect(&:id).sort
  end

  def test_copy_from_existing_project
    source_project = Project.find(1)
    copied_project = Project.copy(1)

    assert copied_project
    # Cleared attributes
    assert copied_project.id.blank?
    assert copied_project.name.blank?
    assert copied_project.identifier.blank?

    # Duplicated attributes
    assert_equal source_project.description, copied_project.description
    assert_equal source_project.enabled_modules, copied_project.enabled_modules
    assert_equal source_project.types, copied_project.types

    # Default attributes
    assert_equal 1, copied_project.status
  end

  def test_activities_should_use_the_system_activities
    project = Project.find(1)
    assert_equal project.activities, TimeEntryActivity.find(:all, conditions: { active: true })
  end

  def test_activities_should_use_the_project_specific_activities
    project = Project.find(1)
    overridden_activity = TimeEntryActivity.new(name: 'Project', project: project)
    assert overridden_activity.save!

    assert project.activities.include?(overridden_activity), 'Project specific Activity not found'
  end

  def test_activities_should_not_include_the_inactive_project_specific_activities
    project = Project.find(1)
    overridden_activity = TimeEntryActivity.new(name: 'Project', project: project, parent: TimeEntryActivity.find(:first), active: false)
    assert overridden_activity.save!

    assert !project.activities.include?(overridden_activity), 'Inactive Project specific Activity found'
  end

  def test_activities_should_not_include_project_specific_activities_from_other_projects
    project = Project.find(1)
    overridden_activity = TimeEntryActivity.new(name: 'Project', project: Project.find(2))
    assert overridden_activity.save!

    assert !project.activities.include?(overridden_activity), 'Project specific Activity found on a different project'
  end

  def test_activities_should_handle_nils
    overridden_activity = TimeEntryActivity.new(name: 'Project', project: Project.find(1), parent: TimeEntryActivity.find(:first))
    TimeEntryActivity.delete_all

    # No activities
    project = Project.find(1)
    assert project.activities.empty?

    # No system, one overridden
    assert overridden_activity.save!
    project.reload
    assert_equal [overridden_activity], project.activities
  end

  def test_activities_should_override_system_activities_with_project_activities
    project = Project.find(1)
    parent_activity = TimeEntryActivity.find(:first)
    overridden_activity = TimeEntryActivity.new(name: 'Project', project: project, parent: parent_activity)
    assert overridden_activity.save!

    assert project.activities.include?(overridden_activity), 'Project specific Activity not found'
    assert !project.activities.include?(parent_activity), 'System Activity found when it should have been overridden'
  end

  def test_activities_should_include_inactive_activities_if_specified
    project = Project.find(1)
    overridden_activity = TimeEntryActivity.new(name: 'Project', project: project, parent: TimeEntryActivity.find(:first), active: false)
    assert overridden_activity.save!

    assert project.activities(true).include?(overridden_activity), 'Inactive Project specific Activity not found'
  end

  test 'activities should not include active System activities if the project has an override that is inactive' do
    project = Project.find(1)
    system_activity = TimeEntryActivity.find_by_name('Design')
    assert system_activity.active?
    overridden_activity = TimeEntryActivity.generate!(project: project, parent: system_activity, active: false)
    assert overridden_activity.save!

    assert !project.activities.include?(overridden_activity), 'Inactive Project specific Activity not found'
    assert !project.activities.include?(system_activity), 'System activity found when the project has an inactive override'
  end

  def test_close_completed_versions
    Version.update_all("status = 'open'")
    project = Project.find(1)
    assert_not_nil project.versions.detect { |v| v.completed? && v.status == 'open' }
    assert_not_nil project.versions.detect { |v| !v.completed? && v.status == 'open' }
    project.close_completed_versions
    project.reload
    assert_nil project.versions.detect { |v| v.completed? && v.status != 'closed' }
    assert_not_nil project.versions.detect { |v| !v.completed? && v.status == 'open' }
  end

  def test_export_work_packages_is_allowed
    project = Project.find(1)
    assert project.allows_to?(:export_work_packages)
  end

  context 'Project#copy' do
    setup do
      ProjectCustomField.destroy_all # Custom values are a mess to isolate in tests
      Project.destroy_all identifier: 'copy-test'
      @source_project = Project.find(2)
      @project = Project.new(name: 'Copy Test', identifier: 'copy-test')
      @project.types = @source_project.types
      @project.enabled_module_names = @source_project.enabled_modules.collect(&:name)
    end

    should 'copy work units' do
      @source_project.work_packages << WorkPackage.generate!(status: Status.find_by_name('Closed'),
                                                             subject: 'copy issue status',
                                                             type_id: 1,
                                                             assigned_to_id: 2,
                                                             project_id: @source_project.id)
      assert @project.valid?
      assert @project.work_packages.empty?
      assert @project.copy(@source_project)

      assert_equal @source_project.work_packages.size, @project.work_packages.size
      @project.work_packages.each do |issue|
        assert issue.valid?
        assert !issue.assigned_to.blank?
        assert_equal @project, issue.project
      end

      copied_issue = @project.work_packages.first(conditions: { subject: 'copy issue status' })
      assert copied_issue
      assert copied_issue.status
      assert_equal 'Closed', copied_issue.status.name
    end

    should 'change the new issues to use the copied version' do
      User.current = User.find(1)
      assigned_version = Version.generate!(name: 'Assigned Issues', status: 'open')
      @source_project.versions << assigned_version
      assert_equal 3, @source_project.versions.size
      FactoryGirl.create(:work_package, project: @source_project,
                                        fixed_version_id: assigned_version.id,
                                        subject: 'change the new issues to use the copied version',
                                        type_id: 1,
                                        project_id: @source_project.id)

      assert @project.copy(@source_project)
      @project.reload
      copied_issue = @project.work_packages.first(conditions: { subject: 'change the new issues to use the copied version' })

      assert copied_issue
      assert copied_issue.fixed_version
      assert_equal 'Assigned Issues', copied_issue.fixed_version.name # Same name
      assert_not_equal assigned_version.id, copied_issue.fixed_version.id # Different record
    end

    should 'copy issue relations' do
      Setting.cross_project_work_package_relations = '1'

      second_issue = WorkPackage.generate!(status_id: 5,
                                           subject: 'copy issue relation',
                                           type_id: 1,
                                           assigned_to_id: 2,
                                           project_id: @source_project.id)
      source_relation = Relation.generate!(from: WorkPackage.find(4),
                                           to: second_issue,
                                           relation_type: 'relates')
      source_relation_cross_project = Relation.generate!(from: WorkPackage.find(1),
                                                         to: second_issue,
                                                         relation_type: 'duplicates')

      assert @project.copy(@source_project)
      assert_equal @source_project.work_packages.count, @project.work_packages.count
      copied_issue = @project.work_packages.find_by_subject('Issue on project 2') # Was #4
      copied_second_issue = @project.work_packages.find_by_subject('copy issue relation')

      # First issue with a relation on project
      assert_equal 1, copied_issue.relations.size, 'Relation not copied'
      copied_relation = copied_issue.relations.first
      assert_equal 'relates', copied_relation.relation_type
      assert_equal copied_second_issue.id, copied_relation.to_id
      assert_not_equal source_relation.id, copied_relation.id

      # Second issue with a cross project relation
      assert_equal 2, copied_second_issue.relations.size, 'Relation not copied'
      copied_relation = copied_second_issue.relations.select { |r| r.relation_type == 'duplicates' }.first
      assert_equal 'duplicates', copied_relation.relation_type
      assert_equal 1, copied_relation.from_id, 'Cross project relation not kept'
      assert_not_equal source_relation_cross_project.id, copied_relation.id
    end

    should 'copy memberships' do
      assert @project.valid?
      assert @project.members.empty?
      assert @project.copy(@source_project)

      assert_equal @source_project.memberships.size, @project.memberships.size
      @project.memberships.each do |membership|
        assert membership
        assert_equal @project, membership.project
      end
    end

    should 'copy memberships with groups and additional roles' do
      group = Group.create!(lastname: 'Copy group')
      user = User.find(7)

      group.users << user

      # group role
      (Member.new.tap do |m|
        m.force_attributes = { project_id: @source_project.id,
                               principal: group,
                               role_ids: [2] }
      end).save!

      member = Member.find_by_user_id_and_project_id(user.id, @source_project.id)
      # additional role
      member.role_ids = [1]

      assert @project.copy(@source_project)
      member = Member.find_by_user_id_and_project_id(user.id, @project.id)
      assert_not_nil member
      assert_equal [1, 2], member.role_ids.sort
    end

    should 'copy project specific queries' do
      assert @project.valid?
      assert @project.queries.empty?
      assert @project.copy(@source_project)

      assert_equal @source_project.queries.size, @project.queries.size
      @project.queries.each do |query|
        assert query
        assert_equal @project, query.project
      end
    end

    should 'copy versions' do
      @source_project.versions << Version.generate!
      @source_project.versions << Version.generate!

      assert @project.versions.empty?
      assert @project.copy(@source_project)

      assert_equal @source_project.versions.size, @project.versions.size
      @project.versions.each do |version|
        assert version
        assert_equal @project, version.project
      end
    end

    should 'copy wiki' do
      assert_difference 'Wiki.count' do
        assert @project.copy(@source_project)
      end

      assert @project.wiki
      assert_not_equal @source_project.wiki, @project.wiki
      assert_equal 'Start page', @project.wiki.start_page
    end

    should 'copy wiki pages and content with hierarchy' do
      assert_difference 'WikiPage.count', @source_project.wiki.pages.size do
        assert @project.copy(@source_project)
      end

      assert @project.wiki
      assert_equal @source_project.wiki.pages.size, @project.wiki.pages.size

      @project.wiki.pages.each do |wiki_page|
        assert wiki_page.content
        assert !@source_project.wiki.pages.include?(wiki_page)
      end

      parent = @project.wiki.find_page('Parent_page')
      child1 = @project.wiki.find_page('Child_page_1')
      child2 = @project.wiki.find_page('Child_page_2')
      assert_equal parent, child1.parent
      assert_equal parent, child2.parent
    end

    should 'copy issue categories' do
      assert @project.copy(@source_project)

      assert_equal 2, @project.categories.size
      @project.categories.each do |category|
        assert !@source_project.categories.include?(category)
      end
    end

    should 'copy boards' do
      assert @project.copy(@source_project)

      assert_equal 1, @project.boards.size
      @project.boards.each do |board|
        assert !@source_project.boards.include?(board)
      end
    end

    should 'change the new issues to use the copied issue categories' do
      issue = WorkPackage.find(4)
      issue.update_attribute(:category_id, 3)

      assert @project.copy(@source_project)

      @project.work_packages.each do |issue|
        assert issue.category
        assert_equal 'Stock management', issue.category.name # Same name
        assert_not_equal Category.find(3), issue.category # Different record
      end
    end

    should 'limit copy with :only option' do
      assert @project.members.empty?
      assert @project.categories.empty?
      assert @source_project.work_packages.any?

      assert @project.copy(@source_project, only: ['members', 'categories'])

      assert @project.members.any?
      assert @project.categories.any?
      assert @project.work_packages.empty?
    end
  end

  context '#start_date' do
    setup do
      ProjectCustomField.destroy_all # Custom values are a mess to isolate in tests
      @project = Project.generate!(identifier: 'test0')
      @project.types << Type.generate!
    end

    should 'be nil if there are no issues on the project' do
      assert_nil @project.start_date
    end

    should 'be tested when issues have no start date'

    should "be the earliest start date of it's issues" do
      early = 7.days.ago.to_date
      FactoryGirl.create(:work_package, project: @project, start_date: Date.today)
      FactoryGirl.create(:work_package, project: @project, start_date: early)

      assert_equal early, @project.start_date
    end
  end

  context '#due_date' do
    setup do
      ProjectCustomField.destroy_all # Custom values are a mess to isolate in tests
      @project = Project.generate!(identifier: 'test0')
      @project.types << Type.generate!
    end

    should 'be nil if there are no issues on the project' do
      assert_nil @project.due_date
    end

    should 'be tested when issues have no due date'

    should "be the latest due date of it's issues" do
      future = 7.days.from_now.to_date
      FactoryGirl.create(:work_package, project: @project, due_date: future)
      FactoryGirl.create(:work_package, project: @project, due_date: Date.today)

      assert_equal future, @project.due_date
    end

    should "be the latest due date of it's versions" do
      future = 7.days.from_now.to_date
      @project.versions << Version.generate!(effective_date: future)
      @project.versions << Version.generate!(effective_date: Date.today)

      assert_equal future, @project.due_date
    end

    should "pick the latest date from it's issues and versions" do
      future = 7.days.from_now.to_date
      far_future = 14.days.from_now.to_date
      FactoryGirl.create(:work_package, project: @project, due_date: far_future)
      @project.versions << Version.generate!(effective_date: future)

      assert_equal far_future, @project.due_date
    end
  end

  context 'Project#completed_percent' do
    setup do
      ProjectCustomField.destroy_all # Custom values are a mess to isolate in tests
      @project = Project.generate!(identifier: 'test0')
      @project.types << Type.generate!
    end

    context 'no versions' do
      should 'be 100' do
        assert_equal 100, @project.completed_percent
      end
    end

    context 'with versions' do
      should 'return 0 if the versions have no issues' do
        Version.generate!(project: @project)
        Version.generate!(project: @project)

        assert_equal 0, @project.completed_percent
      end

      should 'return 100 if the version has only closed issues' do
        v1 = Version.generate!(project: @project)
        FactoryGirl.create(:work_package, project: @project, status: Status.find_by_name('Closed'), fixed_version: v1)
        v2 = Version.generate!(project: @project)
        FactoryGirl.create(:work_package, project: @project, status: Status.find_by_name('Closed'), fixed_version: v2)

        assert_equal 100, @project.completed_percent
      end

      should 'return the averaged completed percent of the versions (not weighted)' do
        v1 = Version.generate!(project: @project)
        FactoryGirl.create(:work_package, project: @project, status: Status.find_by_name('New'), estimated_hours: 10, done_ratio: 50, fixed_version: v1)
        v2 = Version.generate!(project: @project)
        FactoryGirl.create(:work_package, project: @project, status: Status.find_by_name('New'), estimated_hours: 10, done_ratio: 50, fixed_version: v2)

        assert_equal 50, @project.completed_percent
      end
    end
  end

  context '#notified_users' do
    setup do
      @project = Project.generate!
      @role = Role.generate!

      @user_with_membership_notification = User.generate!(mail_notification: 'selected')
      Member.create!(project: @project, principal: @user_with_membership_notification, mail_notification: true) do |member|
        member.role_ids = [@role.id]
      end

      @all_events_user = User.generate!(mail_notification: 'all')
      Member.create!(project: @project, principal: @all_events_user) do |member|
        member.role_ids = [@role.id]
      end

      @no_events_user = User.generate!(mail_notification: 'none')
      Member.create!(project: @project, principal: @no_events_user) do |member|
        member.role_ids = [@role.id]
      end

      @only_my_events_user = User.generate!(mail_notification: 'only_my_events')
      Member.create!(project: @project, principal: @only_my_events_user) do |member|
        member.role_ids = [@role.id]
      end

      @only_assigned_user = User.generate!(mail_notification: 'only_assigned')
      Member.create!(project: @project, principal: @only_assigned_user) do |member|
        member.role_ids = [@role.id]
      end

      @only_owned_user = User.generate!(mail_notification: 'only_owner')
      Member.create!(project: @project, principal: @only_owned_user) do |member|
        member.role_ids = [@role.id]
      end
    end

    should 'include members with a mail notification' do
      assert @project.notified_users.include?(@user_with_membership_notification)
    end

    should "include users with the 'all' notification option" do
      assert @project.notified_users.include?(@all_events_user)
    end

    should "not include users with the 'none' notification option" do
      assert !@project.notified_users.include?(@no_events_user)
    end

    should "not include users with the 'only_my_events' notification option" do
      assert !@project.notified_users.include?(@only_my_events_user)
    end

    should "not include users with the 'only_assigned' notification option" do
      assert !@project.notified_users.include?(@only_assigned_user)
    end

    should "not include users with the 'only_owner' notification option" do
      assert !@project.notified_users.include?(@only_owned_user)
    end
  end
end
