-- Exam Service seed data: 3 courses with 5 questions each. Inserts only when courses is empty.
-- correct_option is a 0-based index into options.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM courses) THEN
        INSERT INTO courses (course_id, name, category) VALUES
            ('f0000000-0000-4000-8000-000000000001', 'Linear Algebra', 'MATH'),
            ('f0000000-0000-4000-8000-000000000002', 'PAD - Distributed Applications', 'NETWORKS'),
            ('f0000000-0000-4000-8000-000000000003', 'FIA - Fundamentals of AI', 'PROGRAMMING');

        INSERT INTO questions (question_id, course_id, text, options, correct_option) VALUES
            ('f1000000-0000-4000-8000-000000000001', 'f0000000-0000-4000-8000-000000000001',
             'What is the determinant of the 2x2 identity matrix?', ARRAY['0', '1', '2', '-1'], 1),
            ('f1000000-0000-4000-8000-000000000002', 'f0000000-0000-4000-8000-000000000001',
             'A square matrix is invertible if and only if its determinant is...', ARRAY['zero', 'positive', 'non-zero', 'one'], 2),
            ('f1000000-0000-4000-8000-000000000003', 'f0000000-0000-4000-8000-000000000001',
             'The rank of a 3x3 zero matrix is:', ARRAY['0', '1', '3', 'undefined'], 0),
            ('f1000000-0000-4000-8000-000000000004', 'f0000000-0000-4000-8000-000000000001',
             'Eigenvalues of a triangular matrix are found on its...', ARRAY['first row', 'last column', 'main diagonal', 'anti-diagonal'], 2),
            ('f1000000-0000-4000-8000-000000000005', 'f0000000-0000-4000-8000-000000000001',
             'The dot product of two orthogonal vectors equals:', ARRAY['1', '0', '-1', 'their lengths multiplied'], 1),

            ('f1000000-0000-4000-8000-000000000006', 'f0000000-0000-4000-8000-000000000002',
             'Which pattern gives every microservice its own database?', ARRAY['Shared database', 'Database per service', 'Saga', 'Sidecar'], 1),
            ('f1000000-0000-4000-8000-000000000007', 'f0000000-0000-4000-8000-000000000002',
             'The CAP theorem says a distributed system cannot fully guarantee all of:', ARRAY['Consistency, Availability, Partition tolerance', 'Caching, Atomicity, Performance', 'Concurrency, Accuracy, Persistence', 'Clustering, Availability, Parallelism'], 0),
            ('f1000000-0000-4000-8000-000000000008', 'f0000000-0000-4000-8000-000000000002',
             'Which component routes client requests to the right microservice?', ARRAY['Message broker', 'API Gateway', 'Load tester', 'ORM'], 1),
            ('f1000000-0000-4000-8000-000000000009', 'f0000000-0000-4000-8000-000000000002',
             'An operation that gives the same result when repeated is called:', ARRAY['atomic', 'idempotent', 'isolated', 'durable'], 1),
            ('f1000000-0000-4000-8000-000000000010', 'f0000000-0000-4000-8000-000000000002',
             'What does a circuit breaker do after repeated failures?', ARRAY['Retries forever', 'Stops calling the failing service for a while', 'Restarts the database', 'Deletes the container'], 1),

            ('f1000000-0000-4000-8000-000000000011', 'f0000000-0000-4000-8000-000000000003',
             'Which search algorithm uses a heuristic plus the path cost so far?', ARRAY['BFS', 'DFS', 'A*', 'Uniform random'], 2),
            ('f1000000-0000-4000-8000-000000000012', 'f0000000-0000-4000-8000-000000000003',
             'Learning from labelled examples is called:', ARRAY['Supervised learning', 'Unsupervised learning', 'Reinforcement learning', 'Transfer learning'], 0),
            ('f1000000-0000-4000-8000-000000000013', 'f0000000-0000-4000-8000-000000000003',
             'In reinforcement learning, the agent tries to maximise its...', ARRAY['loss', 'cumulative reward', 'dataset size', 'learning rate'], 1),
            ('f1000000-0000-4000-8000-000000000014', 'f0000000-0000-4000-8000-000000000003',
             'Minimax is mainly used for:', ARRAY['image recognition', 'two-player games', 'clustering', 'text translation'], 1),
            ('f1000000-0000-4000-8000-000000000015', 'f0000000-0000-4000-8000-000000000003',
             'A model that fits the training data well but fails on new data is:', ARRAY['underfitting', 'overfitting', 'regularised', 'converged'], 1);
    END IF;
END $$;
