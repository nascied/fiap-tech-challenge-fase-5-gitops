CREATE TABLE IF NOT EXISTS ngos (
    id SERIAL PRIMARY KEY,
    name VARCHAR(150) NOT NULL,
    email VARCHAR(100) UNIQUE NOT NULL,
    cause VARCHAR(100) NOT NULL, -- Ex: Proteção Animal, Educação, Fome
    city VARCHAR(100) NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- ON CONFLICT DO NOTHING: este Job roda em TODO helm upgrade (hook
-- pre-install/pre-upgrade), não só na instalação inicial — sem isso, a
-- segunda execução em diante falha com "duplicate key value violates unique
-- constraint ngos_email_key" (erro real, encontrado rodando contra o
-- cluster). donation-service não tem esse problema porque seu init.sql não
-- insere nenhum dado de seed, só cria a tabela.
INSERT INTO ngos (name, email, cause, city) VALUES
('Anjos de Patas', 'contato@anjosdepatas.org', 'Proteção Animal', 'Osasco'),
('Educa Mais', 'info@educamais.org', 'Educação', 'São Paulo')
ON CONFLICT (email) DO NOTHING;
