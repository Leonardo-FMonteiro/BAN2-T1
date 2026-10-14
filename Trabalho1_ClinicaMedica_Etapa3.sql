CREATE TABLE convenio (
	id_convenio SERIAL PRIMARY KEY,
	nome VARCHAR(100)
);


CREATE TABLE paciente (
	id_paciente SERIAL PRIMARY KEY,
	nome VARCHAR(100),
	data_nasc DATE,
	cpf VARCHAR(14),
	rg VARCHAR(20),
	sexo VARCHAR(20),
	endereco VARCHAR(200),
	"e-mail" VARCHAR(100)
);


CREATE TABLE telefone_paciente (
	id_telefone SERIAL PRIMARY KEY,
	numero_telefone VARCHAR(15),
	id_paciente INTEGER REFERENCES paciente(id_paciente)
);


CREATE TABLE plano_convenio (
	id_paciente INTEGER REFERENCES paciente(id_paciente),
	id_convenio INTEGER REFERENCES convenio(id_convenio),
	numero_carteirinha VARCHAR(50),
	validade DATE,
	tipo_plano VARCHAR(50),
	PRIMARY KEY (id_paciente, id_convenio)
);


CREATE TABLE sala (
	id_sala SERIAL PRIMARY KEY,
	descricao VARCHAR(100)
);


CREATE TABLE procedimento (
	id_procedimento SERIAL PRIMARY KEY,
	descricao VARCHAR(200),
	valor NUMERIC(10,2)
);


CREATE TABLE conta (
	id_conta SERIAL PRIMARY KEY,
	valor_procedimento NUMERIC(10,2),
	valor_consulta NUMERIC(10,2),
	valor_total NUMERIC(10,2)
		GENERATED ALWAYS AS
		(valor_procedimento + valor_consulta) STORED
);


CREATE TABLE pagamento (
	id_pagamento SERIAL PRIMARY KEY,
	data_pagamento DATE,
	valor_pago NUMERIC(10,2),
	forma_pagamento VARCHAR(10)
		CHECK (forma_pagamento IN ('CARTAO', 'PIX', 'DINHEIRO')),
	possui_convenio BOOLEAN,
	valor_convenio NUMERIC(10,2),
	id_conta INTEGER REFERENCES conta(id_conta)
);


CREATE TABLE horario (
	id_horario SERIAL PRIMARY KEY,
	hora_inicio TIME,
	hora_fim TIME,
	dia_semana VARCHAR(20)
);


CREATE TABLE medico (
	id_medico SERIAL PRIMARY KEY,
	nome_medico VARCHAR(100),
	percentual_honorario NUMERIC(5,2),
	crm VARCHAR(30) UNIQUE NOT NULL
);


CREATE TABLE telefone_medico (
	id_telefone SERIAL PRIMARY KEY,
	numero_telefone VARCHAR(15),
	id_medico INTEGER REFERENCES medico(id_medico)
);


CREATE TABLE horario_medico (
	id_horario_medico SERIAL PRIMARY KEY,
	id_medico INTEGER REFERENCES medico(id_medico),
	id_horario INTEGER REFERENCES horario(id_horario)
);


CREATE TABLE especialidade (
	id_especialidade SERIAL PRIMARY KEY,
	nome_especialidade VARCHAR(60)
);


CREATE TABLE medico_especialidade (
	id_medico_especialidade SERIAL PRIMARY KEY,
	id_medico INTEGER REFERENCES medico(id_medico),
	id_especialidade INTEGER REFERENCES especialidade(id_especialidade)
);


CREATE TABLE consulta (
	id_consulta SERIAL PRIMARY KEY,
	data_hora_marcado TIMESTAMP,
	data_hora_realizado TIMESTAMP,
	status VARCHAR(30),
	sintomas TEXT,
	diagnostico TEXT,
	prescricao TEXT,

	id_paciente INTEGER REFERENCES paciente(id_paciente),
	id_medico INTEGER REFERENCES medico(id_medico),
	id_sala INTEGER REFERENCES sala(id_sala),
	id_conta INTEGER REFERENCES conta(id_conta)
);


CREATE TABLE consulta_procedimento (
	id_consulta INTEGER REFERENCES consulta(id_consulta),
	id_procedimento INTEGER REFERENCES procedimento(id_procedimento),
	quantidade INTEGER,
	valor_unitario NUMERIC(10,2),

	PRIMARY KEY (id_consulta, id_procedimento)
);

ALTER TABLE conta ALTER COLUMN valor_procedimento SET DEFAULT 0;
ALTER TABLE conta ALTER COLUMN valor_consulta      SET DEFAULT 0;
---================================================================================
--ETAPA 3 GATILHOS E FUNÇÕES
---================================================================================

CREATE OR REPLACE FUNCTION fn_valida_conflito_agenda()
RETURNS TRIGGER AS $$
BEGIN
    -- Ignora consultas canceladas
    IF NEW.status = 'CANCELADA' THEN
        RETURN NEW;
    END IF;

    -- Conflito de médico
    IF EXISTS (
        SELECT 1 FROM consulta c
        WHERE c.id_medico = NEW.id_medico
          AND c.data_hora_marcado = NEW.data_hora_marcado
          AND c.status <> 'CANCELADA'
          AND c.id_consulta <> COALESCE(NEW.id_consulta, -1)
    ) THEN
        RAISE EXCEPTION 'O médico % já possui consulta marcada em %.',
            NEW.id_medico, NEW.data_hora_marcado;
    END IF;

    -- Conflito de sala
    IF NEW.id_sala IS NOT NULL AND EXISTS (
        SELECT 1 FROM consulta c
        WHERE c.id_sala = NEW.id_sala
          AND c.data_hora_marcado = NEW.data_hora_marcado
          AND c.status <> 'CANCELADA'
          AND c.id_consulta <> COALESCE(NEW.id_consulta, -1)
    ) THEN
        RAISE EXCEPTION 'A sala % já está ocupada em %.',
            NEW.id_sala, NEW.data_hora_marcado;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Podemos verificar se um médico trabalha no horário da consulta. Caso contrário não será possível agendar.
-- Os valores de dia_semana devem ser cadastrados no banco em maiúsculas e sem acento!

CREATE TRIGGER trg_valida_conflito_agenda
BEFORE INSERT OR UPDATE OF data_hora_marcado, id_medico, id_sala, status
ON consulta
FOR EACH ROW
EXECUTE FUNCTION fn_valida_conflito_agenda();

CREATE OR REPLACE FUNCTION fn_valida_horario_medico()
RETURNS TRIGGER AS $$
DECLARE
    v_dia_semana TEXT;
    v_hora       TIME;
BEGIN
    IF NEW.status = 'CANCELADA' THEN
        RETURN NEW;
    END IF;

    -- Mapeia o número do dia para o texto usado na tabela horario
    v_dia_semana := CASE EXTRACT(DOW FROM NEW.data_hora_marcado)::INT
        WHEN 0 THEN 'DOMINGO'
        WHEN 1 THEN 'SEGUNDA'
        WHEN 2 THEN 'TERCA'
        WHEN 3 THEN 'QUARTA'
        WHEN 4 THEN 'QUINTA'
        WHEN 5 THEN 'SEXTA'
        WHEN 6 THEN 'SABADO'
    END;
    v_hora := NEW.data_hora_marcado::TIME;

    IF NOT EXISTS (
        SELECT 1
        FROM horario_medico hm
        JOIN horario h ON h.id_horario = hm.id_horario
        WHERE hm.id_medico = NEW.id_medico
          AND UPPER(h.dia_semana) = v_dia_semana
          AND v_hora >= h.hora_inicio
          AND v_hora <  h.hora_fim
    ) THEN
        RAISE EXCEPTION 'O médico % não atende em % às %.',
            NEW.id_medico, v_dia_semana, v_hora;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_valida_horario_medico
BEFORE INSERT OR UPDATE OF data_hora_marcado, id_medico
ON consulta
FOR EACH ROW
EXECUTE FUNCTION fn_valida_horario_medico();


CREATE OR REPLACE FUNCTION fn_atualiza_valor_procedimento_conta()
RETURNS TRIGGER AS $$
DECLARE
    v_consulta_old INTEGER;
    v_consulta_new INTEGER;
BEGIN
    IF TG_OP IN ('UPDATE', 'DELETE') THEN
        v_consulta_old := OLD.id_consulta;
    END IF;
    IF TG_OP IN ('INSERT', 'UPDATE') THEN
        v_consulta_new := NEW.id_consulta;
    END IF;

    -- Recalcula a(s) conta(s) afetada(s).
    -- Se valor_unitario não foi informado, usa o valor cadastrado no procedimento.
    UPDATE conta ct
    SET valor_procedimento = (
        SELECT COALESCE(SUM(cp.quantidade * COALESCE(cp.valor_unitario, p.valor)), 0)
        FROM consulta c
        JOIN consulta_procedimento cp ON cp.id_consulta = c.id_consulta
        JOIN procedimento p ON p.id_procedimento = cp.id_procedimento
        WHERE c.id_conta = ct.id_conta
    )
    WHERE ct.id_conta IN (
        SELECT id_conta
        FROM consulta
        WHERE id_consulta IN (v_consulta_old, v_consulta_new)
    );

    RETURN NULL; -- gatilho AFTER: o retorno é ignorado
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_atualiza_valor_procedimento_conta
AFTER INSERT OR UPDATE OR DELETE
ON consulta_procedimento
FOR EACH ROW
EXECUTE FUNCTION fn_atualiza_valor_procedimento_conta();


TRUNCATE consulta_procedimento, pagamento, consulta, conta, horario_medico,
         telefone_medico, medico_especialidade, especialidade, medico, horario,
         procedimento, sala, plano_convenio, telefone_paciente, paciente, convenio
RESTART IDENTITY CASCADE;

INSERT INTO convenio (nome) VALUES ('Unimed');

INSERT INTO paciente (nome, data_nasc, cpf, rg, sexo, endereco, "e-mail") VALUES
('Maria Silva', '1990-05-10', '111.111.111-11', '1111111', 'FEMININO', 'Rua A, 100', 'maria@email.com'),
('João Souza',  '1985-03-22', '222.222.222-22', '2222222', 'MASCULINO', 'Rua B, 200', 'joao@email.com');

-- Maria: plano válido | João: plano vencido
INSERT INTO plano_convenio (id_paciente, id_convenio, numero_carteirinha, validade, tipo_plano) VALUES
(1, 1, 'CART-001', '2027-12-31', 'ENFERMARIA'),
(2, 1, 'CART-002', '2025-01-31', 'APARTAMENTO');

INSERT INTO sala (descricao) VALUES ('Consultório 1'), ('Consultório 2');

INSERT INTO procedimento (descricao, valor) VALUES
('Eletrocardiograma', 80.00),
('Curativo', 30.00);

INSERT INTO medico (nome_medico, percentual_honorario, crm) VALUES
('Dra. Ana Lima', 40.00, 'CRM-SC 12345');

INSERT INTO especialidade (nome_especialidade) VALUES ('Cardiologia');
INSERT INTO medico_especialidade (id_medico, id_especialidade) VALUES (1, 1);

-- Atende às segundas, das 08:00 às 12:00
INSERT INTO horario (hora_inicio, hora_fim, dia_semana) VALUES ('08:00', '12:00', 'SEGUNDA');
INSERT INTO horario_medico (id_medico, id_horario) VALUES (1, 1);

-- Uma conta por consulta (valor da consulta = 200)
INSERT INTO conta (valor_consulta) VALUES (200.00), (200.00);

-- 19/10/2026 é segunda-feira
INSERT INTO consulta (data_hora_marcado, status, id_paciente, id_medico, id_sala, id_conta) VALUES
('2026-10-19 09:00', 'AGENDADA', 1, 1, 1, 1),
('2026-10-19 10:00', 'AGENDADA', 2, 1, 2, 2);



-- ERRO (gatilho 1): mesmo médico no mesmo horário
INSERT INTO consulta (data_hora_marcado, status, id_paciente, id_medico, id_sala, id_conta)
VALUES ('2026-10-19 09:00', 'AGENDADA', 2, 1, 2, 2);

-- ERRO (gatilho 2): terça-feira, médico não atende
INSERT INTO consulta (data_hora_marcado, status, id_paciente, id_medico, id_sala, id_conta)
VALUES ('2026-10-20 09:00', 'AGENDADA', 2, 1, 2, 2);

--gatilho 3 - conta recalculada
INSERT INTO consulta_procedimento (id_consulta, id_procedimento, quantidade) VALUES (1, 1, 2);
SELECT * FROM conta WHERE id_conta = 1;
-- esperado: valor_procedimento = 160.00, valor_total = 360.00

INSERT INTO consulta_procedimento (id_consulta, id_procedimento, quantidade) VALUES (1, 2, 1);
SELECT * FROM conta WHERE id_conta = 1;
-- esperado: valor_procedimento = 190.00, valor_total = 390.00

DELETE FROM consulta_procedimento WHERE id_consulta = 1 AND id_procedimento = 2;
SELECT * FROM conta WHERE id_conta = 1;
-- esperado: volta para 160.00 / 360.00

--GATILHO 4
-- OK: pagamento parcial em PIX
INSERT INTO pagamento (data_pagamento, valor_pago, forma_pagamento, possui_convenio, id_conta)
VALUES (CURRENT_DATE, 100, 'PIX', FALSE, 1);

-- OK: convênio válido (Maria) -> pago até agora: 200 de 360
INSERT INTO pagamento (data_pagamento, valor_pago, forma_pagamento, possui_convenio, valor_convenio, id_conta)
VALUES (CURRENT_DATE, 0, 'CARTAO', TRUE, 100, 1);

-- ERRO: excede o total (200 + 200 > 360)
INSERT INTO pagamento (data_pagamento, valor_pago, forma_pagamento, possui_convenio, id_conta)
VALUES (CURRENT_DATE, 200, 'DINHEIRO', FALSE, 1);

-- ERRO: convênio vencido (João)
INSERT INTO pagamento (data_pagamento, valor_pago, forma_pagamento, possui_convenio, valor_convenio, id_conta)
VALUES (CURRENT_DATE, 50, 'CARTAO', TRUE, 100, 2);

-- ERRO: valor_convenio sem possui_convenio
INSERT INTO pagamento (data_pagamento, valor_pago, forma_pagamento, possui_convenio, valor_convenio, id_conta)
VALUES (CURRENT_DATE, 50, 'PIX', FALSE, 100, 2);
