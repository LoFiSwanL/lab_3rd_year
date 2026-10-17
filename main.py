import os
from datetime import date
from uuid import uuid4
import psycopg
from psycopg.rows import dict_row

DATABASE_URL = os.getenv('DATABASE_URL')

class ProjectRepository:
    def __init__(self, connection):
        self.connection = connection

    def create(self, client_id, name, start_date):
        row = self.connection.execute(
            'CALL pm.sp_create_project(%s, %s, %s, NULL)',
            (client_id, name, start_date)).fetchone()
        return row['p_id']

    def add_member(self, project_id, employee_id, role_id):
        self.connection.execute('CALL pm.sp_add_member(%s, %s, %s)',
                                (project_id, employee_id, role_id))

    def rename(self, project_id, name):
        self.connection.execute('CALL pm.sp_rename_project(%s, %s)', (project_id, name))

    def delete(self, project_id):
        self.connection.execute('CALL pm.sp_delete_project(%s)', (project_id,))

    def restore(self, project_id):
        self.connection.execute('CALL pm.sp_restore_project(%s)', (project_id,))

    def all(self):
        return self.connection.execute('SELECT * FROM pm.v_projects ORDER BY id').fetchall()

    def members(self, project_id):
        return self.connection.execute(
            'SELECT * FROM pm.v_project_members WHERE project_id = %s', (project_id,)).fetchall()


class TaskRepository:
    def __init__(self, connection):
        self.connection = connection

    def create(self, project_id, assignee_id, priority_id, title, due_date=None):
        return self.connection.execute(
            'CALL pm.sp_create_task(%s, %s, %s, %s, %s, NULL)',
            (project_id, assignee_id, priority_id, title, due_date)).fetchone()['p_id']

    def update(self, task_id, title, status_id):
        self.connection.execute('CALL pm.sp_update_task(%s, %s, %s)',
                                (task_id, title, status_id))

    def delete(self, task_id):
        self.connection.execute('CALL pm.sp_delete_task(%s)', (task_id,))

    def restore(self, task_id):
        self.connection.execute('CALL pm.sp_restore_task(%s)', (task_id,))

    def for_project(self, project_id):
        return self.connection.execute(
            'SELECT * FROM pm.v_tasks WHERE project_id = %s ORDER BY id', (project_id,)).fetchall()


class CommentRepository:
    def __init__(self, connection):
        self.connection = connection

    def add(self, task_id, body):
        return self.connection.execute('CALL pm.sp_add_comment(%s, %s, NULL)',
                                       (task_id, body)).fetchone()['p_id']

    def edit(self, comment_id, body):
        self.connection.execute('CALL pm.sp_edit_comment(%s, %s)', (comment_id, body))

    def delete(self, comment_id):
        self.connection.execute('CALL pm.sp_delete_comment(%s)', (comment_id,))

    def restore(self, comment_id):
        self.connection.execute('CALL pm.sp_restore_comment(%s)', (comment_id,))

    def for_task(self, task_id):
        return self.connection.execute(
            'SELECT * FROM pm.v_comments WHERE task_id = %s ORDER BY id', (task_id,)).fetchall()


class TimeEntryRepository:
    def __init__(self, connection):
        self.connection = connection

    def add(self, task_id, work_date, hours):
        self.connection.execute('CALL pm.sp_log_time(%s, %s, %s)', (task_id, work_date, hours))

    def for_task(self, task_id):
        return self.connection.execute(
            'SELECT * FROM pm.v_time_entries WHERE task_id = %s ORDER BY id', (task_id,)).fetchall()


class UnitOfWork:
    def __init__(self, dsn, actor_id):
        self.dsn = dsn
        self.actor_id = actor_id

    def __enter__(self):
        self.connection = psycopg.connect(
            self.dsn, row_factory=dict_row, cursor_factory=psycopg.ClientCursor,
            options='-c search_path=pm,public')
        try:
            self.connection.execute('CALL pm.sp_set_actor(%s)', (self.actor_id,))
            self.projects = ProjectRepository(self.connection)
            self.tasks = TaskRepository(self.connection)
            self.comments = CommentRepository(self.connection)
            self.time_entries = TimeEntryRepository(self.connection)
            return self
        except BaseException:
            self.connection.close()
            raise

    def __exit__(self, exc_type, exc_value, traceback):
        try:
            if exc_type is None:
                self.connection.commit()
            else:
                self.connection.rollback()
        finally:
            self.connection.close()
        return False


def main():
    # Один Unit of Work атомарно створює проєкт, учасника, завдання та коментар.
    with UnitOfWork(DATABASE_URL, 1) as u:
        project = u.projects.create(1, 'Проєкт ' + uuid4().hex[:6], date.today())
        u.projects.add_member(project, 1, 2)
        task = u.tasks.create(project, 1, 1, 'Розробити базу даних')
        comment = u.comments.add(task, 'Початок роботи')
        u.time_entries.add(task, date.today(), 2)
    print('COMMIT: проєкт, команда, завдання, коментар і час збережено.')

    with UnitOfWork(DATABASE_URL, 2) as u:
        u.projects.rename(project, 'Корпоративний портал')
        u.tasks.update(task, 'Базу даних розроблено', 3)
        u.comments.edit(comment, 'Роботу перевірено')
        row = u.tasks.for_project(project)[0]
        assert row['updated_by'] == 2
        print('Завдання:', row['title'])
        print('Змінив:', row['updated_by'], 'Час:', row['updated_at'])
        print('Прогрес:', next(p['progress_percent'] for p in u.projects.all()
                               if p['id'] == project), '%')
        u.comments.delete(comment)
        assert not u.comments.for_task(task)
        u.comments.restore(comment)
        u.tasks.delete(task)
        assert not u.tasks.for_project(project)
        u.tasks.restore(task)
        u.projects.delete(project)
        assert not u.tasks.for_project(project)
        u.projects.restore(project)
        assert len(u.comments.for_task(task)) == 1
    print('SOFT DELETE / RESTORE: перевірено для 3 сутностей.')

    try:
        with UnitOfWork(DATABASE_URL, 1) as u:
            failed_project = u.projects.create(1, 'Відкат', date.today())
            u.projects.add_member(failed_project, 1, 2)
            failed_task = u.tasks.create(failed_project, 1, 1, 'Не зберігати')
            u.comments.add(failed_task, 'Не зберігати')
            u.time_entries.add(failed_task, date.today(), -1)
    except psycopg.errors.CheckViolation:
        with UnitOfWork(DATABASE_URL, 1) as u:
            assert not any(p['id'] == failed_project for p in u.projects.all())
            assert not u.projects.members(failed_project)
            assert not u.tasks.for_project(failed_project)
            assert not u.comments.for_task(failed_task)
        print('ROLLBACK: помилка від’ємного часу скасувала всю транзакцію.')
    else:
        raise AssertionError('База мала відхилити від’ємний час')


if __name__ == '__main__':
    main()
